#!/bin/sh
# shellcheck disable=SC1090,SC1091,SC2034
# End-to-end task orchestration for CloudflareSpeedTest.

: "${CFST_LIB_DIR:=/usr/libexec/cloudflare-speedtest}"
: "${CFST_CFST_BIN:=/usr/bin/cfst}"
: "${CFST_RUNTIME_DIR:=/tmp/cloudflare-speedtest}"
: "${CFST_SLEEP_CMD:=sleep}"

CFST_CHILD_PID=''
CFST_WATCHDOG_PID=''
CFST_CANCELLED=0
CFST_LOCK_HELD=0

runner_source_libs() {
    # shellcheck source=/dev/null
    . "$CFST_LIB_DIR/config.sh"
    # shellcheck source=/dev/null
    . "$CFST_LIB_DIR/state.sh"
    # shellcheck source=/dev/null
    . "$CFST_LIB_DIR/log.sh"
    # shellcheck source=/dev/null
    . "$CFST_LIB_DIR/lock.sh"
    # shellcheck source=/dev/null
    . "$CFST_LIB_DIR/naming.sh"
    # shellcheck source=/dev/null
    . "$CFST_LIB_DIR/geoip.sh"
    # shellcheck source=/dev/null
    . "$CFST_LIB_DIR/preferred.sh"
    # shellcheck source=/dev/null
    . "$CFST_LIB_DIR/candidates.sh"
    # shellcheck source=/dev/null
    . "$CFST_LIB_DIR/result.sh"
    # shellcheck source=/dev/null
    . "$CFST_LIB_DIR/dns.sh"
}

runner_make_absolute() {
    path="$1"
    case "$path" in
        /*)
            printf '%s' "$path"
            ;;
        *)
            printf '%s/%s' "$(pwd)" "$path"
            ;;
    esac
}

runner_json_field() {
    json="$1"
    field="$2"
    jsonfilter -s "$json" -e "@.$field" 2>/dev/null || true
}

runner_cleanup() {
    if [ -n "${CFST_WATCHDOG_PID:-}" ]; then
        kill "$CFST_WATCHDOG_PID" 2>/dev/null || true
        wait "$CFST_WATCHDOG_PID" 2>/dev/null || true
        CFST_WATCHDOG_PID=''
    fi
    if [ -n "${CFST_CHILD_PID:-}" ]; then
        kill -TERM "$CFST_CHILD_PID" 2>/dev/null || true
        wait "$CFST_CHILD_PID" 2>/dev/null || true
        CFST_CHILD_PID=''
    fi
    if [ "${CFST_LOCK_HELD:-0}" = "1" ]; then
        release_lock 2>/dev/null || true
        CFST_LOCK_HELD=0
    fi
}

runner_on_signal() {
    CFST_CANCELLED=1
    if [ -n "${CFST_CHILD_PID:-}" ]; then
        kill -TERM "$CFST_CHILD_PID" 2>/dev/null || true
    fi
    if [ -n "${CFST_WATCHDOG_PID:-}" ]; then
        kill "$CFST_WATCHDOG_PID" 2>/dev/null || true
    fi
    state_write_status cancelled 'Task cancelled' 2>/dev/null || true
    cfst_log warn 'Task cancelled' 2>/dev/null || true
    exit 130
}

runner_fail() {
    code="$1"
    message="$2"
    exit_code="${3:-1}"
    CFST_ERROR_CODE="$code"
    CFST_ERROR_MESSAGE="$message"
    state_fail "$code" "$message" 2>/dev/null || true
    cfst_log error "$message" 2>/dev/null || true
    return "$exit_code"
}

# CFST -f only accepts bare IPv4/CIDR lines; strip comments/blanks defensively.
runner_prepare_ip_file() {
    src="$1"
    dest="$2"
    [ -f "$src" ] || return 1
    awk '
        {
            sub(/\r$/, "")
            sub(/#.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if ($0 == "") next
            if ($0 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/) print $0
        }
    ' "$src" > "$dest"
    [ -s "$dest" ]
}

runner_run_cfst() {
    ip_file="$1"
    out_file="$2"
    latency_only="${3:-0}"

    threads="${CFST_THREADS:-50}"
    attempts="${CFST_ATTEMPTS:-4}"
    download_count="${CFST_DOWNLOAD_COUNT:-5}"
    download_seconds="${CFST_DOWNLOAD_SECONDS:-10}"
    port="${CFST_PORT:-443}"
    max_latency="${CFST_MAX_LATENCY_MS:-200}"
    max_loss="${CFST_MAX_LOSS_RATIO:-0.2}"
    test_url="${CFST_TEST_URL:-https://speed.cloudflare.com/__down?bytes=99000000}"
    timeout="${CFST_TASK_TIMEOUT:-900}"
    if [ -n "${CFST_TASK_TIMEOUT_OVERRIDE:-}" ]; then
        timeout="$CFST_TASK_TIMEOUT_OVERRIDE"
    fi

    prepared_ip="${CFST_TASK_DIR:-/tmp}/ip-prepared.$$"
    if ! runner_prepare_ip_file "$ip_file" "$prepared_ip"; then
        rm -f "$prepared_ip"
        runner_fail CFST_EXEC_FAILED 'IP 列表无效或为空'
        return 53
    fi

    timed_out_flag="${CFST_TASK_DIR:-/tmp}/cfst-timed-out.$$"
    rm -f "$timed_out_flag"

    cfst_args=""
    if [ "$latency_only" = "1" ]; then
        cfst_args="-dd"
    fi
    allip_arg=""
    # -allip expands CIDR ranges inside CFST. Preferred-provider responses
    # are already a finite list of individual IPv4 addresses; keep -allip
    # only for the normal CIDR source.
    if [ "${CFST_TEST_ALL:-0}" = "1" ] && [ "${CFST_IP_SOURCE:-cidr}" != "preferred" ]; then
        allip_arg="-allip"
    fi

    # Keep the arguments discrete. The option strings above are controlled by
    # validated internal flags, not user input.
    if [ "$latency_only" = "1" ] && [ -n "$allip_arg" ]; then
        "$CFST_CFST_BIN" -f "$prepared_ip" -o "$out_file" -p 0 \
            -n "$threads" -t "$attempts" -dn "$download_count" \
            -dt "$download_seconds" -tp "$port" -tl "$max_latency" \
            -tlr "$max_loss" -url "$test_url" -dd -allip &
    elif [ "$latency_only" = "1" ]; then
        "$CFST_CFST_BIN" -f "$prepared_ip" -o "$out_file" -p 0 \
            -n "$threads" -t "$attempts" -dn "$download_count" \
            -dt "$download_seconds" -tp "$port" -tl "$max_latency" \
            -tlr "$max_loss" -url "$test_url" -dd &
    elif [ -n "$allip_arg" ]; then
        "$CFST_CFST_BIN" -f "$prepared_ip" -o "$out_file" -p 0 \
            -n "$threads" -t "$attempts" -dn "$download_count" \
            -dt "$download_seconds" -tp "$port" -tl "$max_latency" \
            -tlr "$max_loss" -url "$test_url" -allip &
    else
        "$CFST_CFST_BIN" -f "$prepared_ip" -o "$out_file" -p 0 \
            -n "$threads" -t "$attempts" -dn "$download_count" \
            -dt "$download_seconds" -tp "$port" -tl "$max_latency" \
            -tlr "$max_loss" -url "$test_url" &
    fi
    CFST_CHILD_PID=$!

    if [ "${CFST_DISABLE_WATCHDOG:-0}" != "1" ]; then
        (
            sleep "$timeout"
            touch "$timed_out_flag" 2>/dev/null || true
            kill -TERM "$CFST_CHILD_PID" 2>/dev/null || true
        ) &
        CFST_WATCHDOG_PID=$!
    fi

    wait_status=0
    wait "$CFST_CHILD_PID" || wait_status=$?
    CFST_CHILD_PID=''

    if [ -n "${CFST_WATCHDOG_PID:-}" ]; then
        kill "$CFST_WATCHDOG_PID" 2>/dev/null || true
        wait "$CFST_WATCHDOG_PID" 2>/dev/null || true
        CFST_WATCHDOG_PID=''
    fi

    rm -f "$prepared_ip"

    if [ "${CFST_CANCELLED:-0}" = "1" ]; then
        rm -f "$timed_out_flag"
        state_write_status cancelled 'Task cancelled' 2>/dev/null || true
        return 130
    fi

    if [ ! -f "$out_file" ] || [ ! -s "$out_file" ]; then
        if [ -f "$timed_out_flag" ]; then
            rm -f "$timed_out_flag"
            runner_fail CFST_TIMEOUT '测速任务超时'
            return 52
        fi
        rm -f "$timed_out_flag"
        if [ "$wait_status" -eq 0 ]; then
            # Upstream exits 0 without CSV when no address survives the
            # latency/loss pre-filter. The adaptive caller treats this as a
            # signal to enlarge its candidate set.
            return 51
        fi
        runner_fail CFST_EXEC_FAILED "cfst 接口异常退出（exit=$wait_status），未产生结果文件"
        return 53
    fi

    rm -f "$timed_out_flag"
    if [ "$wait_status" -ne 0 ]; then
        cfst_log warn "cfst exited with status $wait_status; validating output"
    fi
    return 0
}

runner_build_tested_json() {
    best="$1"
    hostname="${2:-}"
    info="${3:-}"
    ip="$(runner_json_field "$best" ip)"
    latency="$(runner_json_field "$best" latency_ms)"
    loss="$(runner_json_field "$best" loss_ratio)"
    speed="$(runner_json_field "$best" speed_mbps)"
    colo="$(runner_json_field "$best" colo)"
    escaped_ip="$(json_escape "$ip")"
    escaped_colo="$(json_escape "$colo")"
    escaped_host="$(json_escape "$hostname")"
    region="$(runner_json_field "$info" region)"
    city="$(runner_json_field "$info" city)"
    isp="$(runner_json_field "$info" isp)"
    asn="$(runner_json_field "$info" asn)"
    llc="$(runner_json_field "$info" llc)"
    source="$(runner_json_field "$info" source)"
    escaped_region="$(json_escape "$region")"
    escaped_city="$(json_escape "$city")"
    escaped_isp="$(json_escape "$isp")"
    escaped_asn="$(json_escape "$asn")"
    escaped_llc="$(json_escape "$llc")"
    escaped_source="$(json_escape "$source")"
    now="$(cfst_now)"
    suffix=",\"region\":\"$escaped_region\",\"city\":\"$escaped_city\",\"isp\":\"$escaped_isp\",\"asn\":\"$escaped_asn\",\"llc\":\"$escaped_llc\",\"geo_source\":\"$escaped_source\",\"tested_at\":$now"
    if [ -n "$hostname" ]; then
        printf '{"ip":"%s","latency_ms":%s,"loss_ratio":%s,"speed_mbps":%s,"colo":"%s","hostname":"%s"%s}' \
            "$escaped_ip" "$latency" "$loss" "$speed" "$escaped_colo" "$escaped_host" "$suffix"
    else
        printf '{"ip":"%s","latency_ms":%s,"loss_ratio":%s,"speed_mbps":%s,"colo":"%s"%s}' \
            "$escaped_ip" "$latency" "$loss" "$speed" "$escaped_colo" "$suffix"
    fi
}

runner_build_published_json() {
    best="$1"
    hostname="$2"
    info="${3:-}"
    ip="$(runner_json_field "$best" ip)"
    latency="$(runner_json_field "$best" latency_ms)"
    loss="$(runner_json_field "$best" loss_ratio)"
    speed="$(runner_json_field "$best" speed_mbps)"
    colo="$(runner_json_field "$best" colo)"
    escaped_ip="$(json_escape "$ip")"
    escaped_colo="$(json_escape "$colo")"
    escaped_host="$(json_escape "$hostname")"
    region="$(runner_json_field "$info" region)"
    city="$(runner_json_field "$info" city)"
    isp="$(runner_json_field "$info" isp)"
    asn="$(runner_json_field "$info" asn)"
    llc="$(runner_json_field "$info" llc)"
    source="$(runner_json_field "$info" source)"
    now="$(cfst_now)"
    printf '{"ip":"%s","latency_ms":%s,"loss_ratio":%s,"speed_mbps":%s,"colo":"%s","hostname":"%s","region":"%s","city":"%s","isp":"%s","asn":"%s","llc":"%s","geo_source":"%s","published_at":%s}' \
        "$escaped_ip" "$latency" "$loss" "$speed" "$escaped_colo" "$escaped_host" \
        "$(json_escape "$region")" "$(json_escape "$city")" "$(json_escape "$isp")" "$(json_escape "$asn")" "$(json_escape "$llc")" "$(json_escape "$source")" "$now"
}

runner_update_network_cache() {
    identity="$1"
    queried_at="$(runner_json_field "$identity" queried_at)"
    ip="$(runner_json_field "$identity" ip)"
    [ -n "$queried_at" ] && [ -n "$ip" ] || return 0
    case "$queried_at" in ''|*[!0-9]*) return 0 ;; esac
    CFST_NETWORK_CACHE="$(printf '{"ip":"%s","region":"%s","city":"%s","isp":"%s","asn":"%s","llc":"%s","queried_at":%s}' \
        "$(json_escape "$ip")" "$(json_escape "$(runner_json_field "$identity" region)")" \
        "$(json_escape "$(runner_json_field "$identity" city)")" \
        "$(json_escape "$(runner_json_field "$identity" isp)")" "$(json_escape "$(runner_json_field "$identity" asn)")" \
        "$(json_escape "$(runner_json_field "$identity" llc)")" "$queried_at")"
    export CFST_NETWORK_CACHE
}

runner_update_geo_cache() {
    identity="$1"
    [ -n "$identity" ] || return 0
    city="$(runner_json_field "$identity" city)"
    isp="$(runner_json_field "$identity" isp)"
    ip="$(runner_json_field "$identity" ip)"
    source="$(runner_json_field "$identity" source)"
    region="$(runner_json_field "$identity" region)"
    asn="$(runner_json_field "$identity" asn)"
    llc="$(runner_json_field "$identity" llc)"
    [ -n "$city" ] && [ -n "$isp" ] || return 0
    escaped_city="$(json_escape "$city")"
    escaped_isp="$(json_escape "$isp")"
    escaped_ip="$(json_escape "$ip")"
    escaped_source="$(json_escape "$source")"
    escaped_region="$(json_escape "$region")"
    escaped_asn="$(json_escape "$asn")"
    escaped_llc="$(json_escape "$llc")"
    now="$(cfst_now)"
    CFST_GEO_CACHE="$(printf '{"ip":"%s","region":"%s","city":"%s","isp":"%s","asn":"%s","llc":"%s","source":"%s","cached_at":%s}' \
        "$escaped_ip" "$escaped_region" "$escaped_city" "$escaped_isp" "$escaped_asn" "$escaped_llc" "$escaped_source" "$now")"
}

# run_task MODE TRIGGER
# MODE: test-only | test-and-update
# TRIGGER: manual | cron | hotplug
run_task() {
    mode="$1"
    trigger="$2"
    rc=0

    CFST_CANCELLED=0
    CFST_CHILD_PID=''
    CFST_WATCHDOG_PID=''
    CFST_LOCK_HELD=0
    CFST_ERROR_CODE=''
    CFST_ERROR_MESSAGE=''

    load_config

    if [ "$mode" = "test-and-update" ]; then
        if ! validate_publish_config; then
            code="${CFST_ERROR_CODE:-CONFIG_INVALID}"
            msg="${CFST_ERROR_MESSAGE:-配置无效}"
            mkdir -p "${CFST_RUNTIME_DIR}" 2>/dev/null || true
            state_fail "$code" "$msg" 2>/dev/null || true
            cfst_log error "$msg" 2>/dev/null || true
            case "$code" in
                CONFIG_TOKEN_MISSING|CONFIG_ZONE_MISSING) return 20 ;;
                *) return 21 ;;
            esac
        fi
    else
        if ! validate_base_config; then
            code="${CFST_ERROR_CODE:-CONFIG_INVALID}"
            msg="${CFST_ERROR_MESSAGE:-配置无效}"
            mkdir -p "${CFST_RUNTIME_DIR}" 2>/dev/null || true
            state_fail "$code" "$msg" 2>/dev/null || true
            cfst_log error "$msg" 2>/dev/null || true
            return 21
        fi
    fi

    # Harness-only override applied after validation so short timeouts are testable.
    if [ -n "${CFST_TASK_TIMEOUT_OVERRIDE:-}" ]; then
        CFST_TASK_TIMEOUT="$CFST_TASK_TIMEOUT_OVERRIDE"
    fi

    mkdir -p "$CFST_RUNTIME_DIR" || return 1
    CFST_TASK_DIR="$CFST_RUNTIME_DIR/run.$$"
    mkdir -p "$CFST_TASK_DIR" || return 1
    export CFST_TASK_DIR

    : "${CFST_LOCK_DIR:=$CFST_RUNTIME_DIR/lock}"
    export CFST_LOCK_DIR

    set +e
    acquire_lock "$trigger"
    lock_status=$?
    set -e
    if [ "$lock_status" -ne 0 ]; then
        code="${CFST_ERROR_CODE:-TASK_ALREADY_RUNNING}"
        msg="${CFST_ERROR_MESSAGE:-已有测速任务正在运行}"
        state_fail "$code" "$msg" 2>/dev/null || true
        cfst_log error "$msg" 2>/dev/null || true
        return "$lock_status"
    fi
    CFST_LOCK_HELD=1

    trap 'runner_cleanup' EXIT
    trap 'runner_on_signal' INT TERM

    state_init "$trigger"
    cfst_log info "Task started mode=$mode trigger=$trigger"

    set +e
    state_load_persistent
    set -e

    # Run six-hourly cleanup independently of whether this run later produces
    # a qualified result. This keeps expired preferred-IP metadata bounded.
    ipinfo_cleanup_if_due 2>/dev/null || true

    # --- detecting_network ---
    state_set_phase detecting_network '正在检测网络信息'
    cfst_log info 'phase=detecting_network'
    identity=''
    hostname=''
    if naming_template_is_custom "${CFST_NAMING_TEMPLATE}"; then
        # The hostname is custom, but still maintain the low-frequency UAPI
        # network cache for accurate local-IP information.
        # Local-location metadata is still needed for the dashboard and for
        # preferred-provider auto-selection. The auto-detect switch controls
        # only use of city/ISP in the hostname; a custom hostname must not
        # suppress the low-frequency UAPIS lookup.
        saved_auto_detect="${CFST_AUTO_DETECT:-1}"
        CFST_AUTO_DETECT=1
        set +e
        identity="$(resolve_network_identity 2>/dev/null)"
        set -e
        CFST_AUTO_DETECT="$saved_auto_detect"
        if [ -n "$identity" ]; then
            runner_update_network_cache "$identity"
            runner_update_geo_cache "$identity"
        fi
        hostname="$(render_hostname "${CFST_NAMING_TEMPLATE}" '' '' "${CFST_ZONE}")"
        name_status=$?
        set -e
        if [ "$name_status" -ne 0 ]; then
            hostname=''
            cfst_log warn "hostname unresolved: ${CFST_ERROR_MESSAGE:-unknown}"
        fi
    else
        set +e
        identity="$(resolve_network_identity)"
        geo_status=$?
        set -e
        if [ "$geo_status" -eq 0 ] && [ -n "$identity" ]; then
            runner_update_network_cache "$identity"
            runner_update_geo_cache "$identity"
            city="$(runner_json_field "$identity" city)"
            isp="$(runner_json_field "$identity" isp)"
            set +e
            hostname="$(render_hostname "${CFST_NAMING_TEMPLATE}" "$city" "$isp" "${CFST_ZONE}")"
            name_status=$?
            set -e
            if [ "$name_status" -ne 0 ]; then
                hostname=''
                cfst_log warn "hostname unresolved: ${CFST_ERROR_MESSAGE:-unknown}"
            fi
        else
            cfst_log warn "network identity unresolved: ${CFST_ERROR_MESSAGE:-geo failed}"
            if [ "$mode" = "test-and-update" ]; then
                # Still allow speed test; DNS skipped later if no hostname
                :
            fi
        fi
    fi

    # --- testing ---
    state_set_phase testing '正在测速'
    cfst_log info 'phase=testing'
    ip_source_abs="$(runner_make_absolute "$CFST_IP_FILE")"
    preferred_ip=""
    if [ "${CFST_IP_SOURCE:-cidr}" = "preferred" ]; then
        preferred_ip="$CFST_TASK_DIR/preferred-ips.txt"
        if ! preferred_prepare_ip_file "$identity" "$preferred_ip"; then
            code="${CFST_ERROR_CODE:-PREFERRED_IPS_EMPTY}"
            msg="${CFST_ERROR_MESSAGE:-优选反代地址未返回可用 IP}"
            runner_fail "$code" "$msg" 54
            return 54
        fi
        ip_source_abs="$preferred_ip"
        cfst_log info "preferred_ips provider=${CFST_PREFERRED_SELECTED_PROVIDER:-unknown} count=${CFST_PREFERRED_SELECTED_COUNT:-0}"
    fi

    # Build the finite working set. candidate_count=0 and test_all=1 both mean
    # no sampling. For a finite set, preflight in latency-only mode and enlarge
    # by ceil(1.5x) until an IP passes the latency/loss gate or the source is
    # exhausted. The selected working file is then used for download ranking.
    candidate_source="$CFST_TASK_DIR/candidate-source.txt"
    candidate_file="$CFST_TASK_DIR/candidates.txt"
    if ! candidates_prepare "$ip_source_abs" "$candidate_source" 0 1; then
        runner_fail CFST_EXEC_FAILED '无法准备候选 IP 列表' 53
        return 53
    fi
    candidate_available="${CFST_CANDIDATE_AVAILABLE:-0}"
    requested_count="${CFST_CANDIDATE_COUNT:-0}"
    current_count="$requested_count"
    if [ "$requested_count" -gt 0 ] && [ "$candidate_available" -gt 0 ] && [ "$current_count" -gt "$candidate_available" ]; then
        current_count="$candidate_available"
    fi

    # For unlimited/all mode preserve the complete source and let cfst do the
    # normal one-pass latency + download workflow.
    if [ "$requested_count" -eq 0 ] || [ "${CFST_TEST_ALL:-0}" = "1" ]; then
        cp "$candidate_source" "$candidate_file"
        if [ ! -s "$candidate_file" ]; then
            runner_fail CFST_EXEC_FAILED '候选 IP 列表为空' 53
            return 53
        fi
        ip_source_abs="$candidate_file"
    else
        preflight_out="$CFST_TASK_DIR/preflight.csv"
        found_qualified=0
        while [ "$current_count" -gt 0 ]; do
            if ! candidates_prepare "$ip_source_abs" "$candidate_file" "$current_count" 0; then
                runner_fail CFST_EXEC_FAILED '无法抽取候选 IP' 53
                return 53
            fi
            cfst_log info "latency_preflight candidates=$current_count available=$candidate_available"
            state_set_phase testing_latency "正在测试延迟候选 IP（$current_count）"
            rm -f "$preflight_out"
            set +e
            runner_run_cfst "$candidate_file" "$preflight_out" 1
            preflight_status=$?
            set -e
            if [ "$preflight_status" -eq 130 ] || [ "${CFST_CANCELLED:-0}" = "1" ]; then
                state_write_status cancelled 'Task cancelled'
                return 130
            fi
            if [ "$preflight_status" -eq 52 ]; then
                return 52
            fi
            if [ -f "$preflight_out" ] && result_has_qualified_latency "$preflight_out" "$CFST_MAX_LATENCY_MS" "$CFST_MAX_LOSS_RATIO"; then
                found_qualified=1
                cfst_log info "latency_preflight qualified candidates=$current_count"
                break
            fi
            if [ "$current_count" -ge "$candidate_available" ]; then
                break
            fi
            next_count="$(candidates_next_count "$current_count")"
            [ "$next_count" -le "$candidate_available" ] || next_count="$candidate_available"
            cfst_log warn "latency_preflight no qualified result; expanding candidates=$current_count next=$next_count"
            current_count="$next_count"
        done
        if [ "$found_qualified" -ne 1 ]; then
            runner_fail RESULT_NO_QUALIFIED_IP '没有符合当前测速条件的结果' 51
            return 51
        fi
        ip_source_abs="$candidate_file"
    fi

    out_abs="$(runner_make_absolute "$CFST_TASK_DIR/result.csv")"
    set +e
    runner_run_cfst "$ip_source_abs" "$out_abs" 0
    cfst_status=$?
    set -e
    if [ "$cfst_status" -ne 0 ]; then
        if [ "$cfst_status" -eq 51 ]; then
            runner_fail RESULT_NO_QUALIFIED_IP '没有符合当前测速条件的结果' 51
        fi
        return "$cfst_status"
    fi
    if [ "${CFST_CANCELLED:-0}" = "1" ]; then
        state_write_status cancelled 'Task cancelled'
        return 130
    fi

    # --- validating_result ---
    state_set_phase validating_result '正在验证测速结果'
    cfst_log info 'phase=validating_result'
    set +e
    best="$(select_best_result "$out_abs" "$CFST_MAX_LATENCY_MS" "$CFST_MAX_LOSS_RATIO" "$CFST_MIN_SPEED_MBPS")"
    result_status=$?
    set -e
    if [ "$result_status" -ne 0 ]; then
        code="${CFST_ERROR_CODE:-RESULT_NO_QUALIFIED_IP}"
        msg="${CFST_ERROR_MESSAGE:-没有符合条件的测速结果}"
        runner_fail "$code" "$msg" "$result_status"
        return "$result_status"
    fi

    selected_ip="$(runner_json_field "$best" ip)"
    selected_info="$(ipinfo_get_or_query "$selected_ip" 2>/dev/null || true)"
    if [ -z "$selected_info" ]; then
        cfst_log warn "preferred IP info unavailable ip=$selected_ip"
    fi
    CFST_LAST_TESTED="$(runner_build_tested_json "$best" "$hostname" "$selected_info")"
    state_save_persistent
    cfst_log info "qualified result saved ip=$(runner_json_field "$best" ip)"

    if [ "$mode" = "test-only" ]; then
        state_success '测速完成'
        cfst_log info 'phase=success test-only'
        return 0
    fi

    # --- updating_dns ---
    if [ -z "$hostname" ]; then
        runner_fail NAMING_UNRESOLVED '测速成功，但无法确定 DNS 主机名' 40
        return 40
    fi

    state_set_phase updating_dns '正在更新 Cloudflare DNS'
    cfst_log info "phase=updating_dns hostname=$hostname"
    ip="$(runner_json_field "$best" ip)"

    # Preserve prior publication on failure
    prior_published="${CFST_LAST_PUBLISHED:-}"

    set +e
    cf_sync_dns "$hostname" "$ip"
    dns_status=$?
    set -e

    if [ "$dns_status" -eq 0 ]; then
        CFST_LAST_PUBLISHED="$(runner_build_published_json "$best" "$hostname" "$selected_info")"
        state_save_persistent
        # A manual publish is a full successful refresh. Re-anchor cron from
        # completion so the next automatic run is one configured interval away.
        # A schedule write failure must not turn an already-published DNS record
        # into a failed task; retain the normal cron line and log the warning.
        if [ "$trigger" = "manual" ] && [ -f "$CFST_LIB_DIR/schedule.sh" ]; then
            # shellcheck source=/dev/null
            . "$CFST_LIB_DIR/schedule.sh"
            if schedule_defer_after_manual_success; then
                cfst_log info "next scheduled task deferred until ${CFST_SCHEDULE_NEXT_RUN_AT:-unknown}"
            else
                cfst_log warn 'DNS 已发布，但无法推迟下次定时任务'
            fi
        fi
        state_success 'DNS 记录已发布'
        cfst_log info 'phase=success dns published'
        return 0
    fi

    if [ "$dns_status" -eq 66 ]; then
        # New record published; cleanup failed
        CFST_LAST_PUBLISHED="$(runner_build_published_json "$best" "$hostname" "$selected_info")"
        state_save_persistent
        state_write_status partial_success "${CFST_ERROR_MESSAGE:-新记录已发布但旧记录清理失败}" \
            "\"error_code\":\"${CFST_ERROR_CODE:-DNS_CLEANUP_FAILED}\""
        cfst_log error 'phase=partial_success cleanup failed after publish'
        return 66
    fi

    # DNS failed: keep prior publication, keep last_tested
    CFST_LAST_PUBLISHED="$prior_published"
    state_save_persistent
    code="${CFST_ERROR_CODE:-CF_API_TEMPORARY}"
    msg="${CFST_ERROR_MESSAGE:-DNS 更新失败}"
    runner_fail "$code" "$msg" "$dns_status"
    return "$dns_status"
}

# Allow direct execution: runner.sh test-only manual
if [ "${0##*/}" = "runner.sh" ] && [ "$#" -ge 1 ]; then
    runner_source_libs
    run_task "$1" "${2:-manual}"
    exit $?
fi
