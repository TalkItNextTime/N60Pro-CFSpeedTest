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
    . "$CFST_LIB_DIR/result.sh"
    # shellcheck source=/dev/null
    . "$CFST_LIB_DIR/dns.sh"
}

runner_make_absolute() {
    path="$1"
    case "$path" in
        /*|[A-Za-z]:/*|[A-Za-z]:\\*)
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

runner_run_cfst() {
    ip_file="$1"
    out_file="$2"

    threads="${CFST_THREADS:-50}"
    attempts="${CFST_ATTEMPTS:-4}"
    download_count="${CFST_DOWNLOAD_COUNT:-5}"
    download_seconds="${CFST_DOWNLOAD_SECONDS:-10}"
    port="${CFST_PORT:-443}"
    max_latency="${CFST_MAX_LATENCY_MS:-200}"
    max_loss="${CFST_MAX_LOSS_RATIO:-0.2}"
    timeout="${CFST_TASK_TIMEOUT:-900}"
    if [ -n "${CFST_TASK_TIMEOUT_OVERRIDE:-}" ]; then
        timeout="$CFST_TASK_TIMEOUT_OVERRIDE"
    fi

    nice -n 10 "$CFST_CFST_BIN" \
        -f "$ip_file" \
        -o "$out_file" \
        -p 0 \
        -n "$threads" \
        -t "$attempts" \
        -dn "$download_count" \
        -dt "$download_seconds" \
        -tp "$port" \
        -tl "$max_latency" \
        -tlr "$max_loss" &
    CFST_CHILD_PID=$!

    (
        ${CFST_SLEEP_CMD:-sleep} "$timeout"
        kill -TERM "$CFST_CHILD_PID" 2>/dev/null || true
    ) &
    CFST_WATCHDOG_PID=$!

    wait_status=0
    wait "$CFST_CHILD_PID" || wait_status=$?
    CFST_CHILD_PID=''

    if [ -n "${CFST_WATCHDOG_PID:-}" ]; then
        kill "$CFST_WATCHDOG_PID" 2>/dev/null || true
        wait "$CFST_WATCHDOG_PID" 2>/dev/null || true
        CFST_WATCHDOG_PID=''
    fi

    if [ "${CFST_CANCELLED:-0}" = "1" ]; then
        return 130
    fi

    if [ ! -f "$out_file" ] || [ ! -s "$out_file" ]; then
        if [ "$wait_status" -ne 0 ] || [ -n "${CFST_TASK_TIMEOUT_OVERRIDE:-}" ]; then
            runner_fail CFST_TIMEOUT '测速任务超时' 52
            return 52
        fi
        runner_fail CFST_EXEC_FAILED 'cfst 未产生结果文件' 53
        return 53
    fi

    if [ "$wait_status" -ne 0 ]; then
        # Output exists; continue to validation despite non-zero exit.
        cfst_log warn "cfst exited with status $wait_status; validating output"
    fi
    return 0
}

runner_build_tested_json() {
    best="$1"
    hostname="${2:-}"
    ip="$(runner_json_field "$best" ip)"
    latency="$(runner_json_field "$best" latency_ms)"
    loss="$(runner_json_field "$best" loss_ratio)"
    speed="$(runner_json_field "$best" speed_mbps)"
    colo="$(runner_json_field "$best" colo)"
    escaped_ip="$(json_escape "$ip")"
    escaped_colo="$(json_escape "$colo")"
    escaped_host="$(json_escape "$hostname")"
    now="$(cfst_now)"
    if [ -n "$hostname" ]; then
        printf '{"ip":"%s","latency_ms":%s,"loss_ratio":%s,"speed_mbps":%s,"colo":"%s","hostname":"%s","tested_at":%s}' \
            "$escaped_ip" "$latency" "$loss" "$speed" "$escaped_colo" "$escaped_host" "$now"
    else
        printf '{"ip":"%s","latency_ms":%s,"loss_ratio":%s,"speed_mbps":%s,"colo":"%s","tested_at":%s}' \
            "$escaped_ip" "$latency" "$loss" "$speed" "$escaped_colo" "$now"
    fi
}

runner_build_published_json() {
    best="$1"
    hostname="$2"
    ip="$(runner_json_field "$best" ip)"
    latency="$(runner_json_field "$best" latency_ms)"
    loss="$(runner_json_field "$best" loss_ratio)"
    speed="$(runner_json_field "$best" speed_mbps)"
    colo="$(runner_json_field "$best" colo)"
    escaped_ip="$(json_escape "$ip")"
    escaped_colo="$(json_escape "$colo")"
    escaped_host="$(json_escape "$hostname")"
    now="$(cfst_now)"
    printf '{"ip":"%s","latency_ms":%s,"loss_ratio":%s,"speed_mbps":%s,"colo":"%s","hostname":"%s","published_at":%s}' \
        "$escaped_ip" "$latency" "$loss" "$speed" "$escaped_colo" "$escaped_host" "$now"
}

runner_update_geo_cache() {
    identity="$1"
    [ -n "$identity" ] || return 0
    city="$(runner_json_field "$identity" city)"
    isp="$(runner_json_field "$identity" isp)"
    ip="$(runner_json_field "$identity" ip)"
    source="$(runner_json_field "$identity" source)"
    [ -n "$city" ] && [ -n "$isp" ] || return 0
    escaped_city="$(json_escape "$city")"
    escaped_isp="$(json_escape "$isp")"
    escaped_ip="$(json_escape "$ip")"
    escaped_source="$(json_escape "$source")"
    now="$(cfst_now)"
    CFST_GEO_CACHE="$(printf '{"ip":"%s","city":"%s","isp":"%s","source":"%s","cached_at":%s}' \
        "$escaped_ip" "$escaped_city" "$escaped_isp" "$escaped_source" "$now")"
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

    # --- detecting_network ---
    state_set_phase detecting_network 'Detecting network identity'
    cfst_log info 'phase=detecting_network'
    identity=''
    hostname=''
    set +e
    identity="$(resolve_network_identity)"
    geo_status=$?
    set -e
    if [ "$geo_status" -eq 0 ] && [ -n "$identity" ]; then
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

    # --- testing ---
    state_set_phase testing 'Running speed test'
    cfst_log info 'phase=testing'
    ip_abs="$(runner_make_absolute "$CFST_IP_FILE")"
    out_abs="$(runner_make_absolute "$CFST_TASK_DIR/result.csv")"

    set +e
    runner_run_cfst "$ip_abs" "$out_abs"
    cfst_status=$?
    set -e
    if [ "$cfst_status" -ne 0 ]; then
        return "$cfst_status"
    fi
    if [ "${CFST_CANCELLED:-0}" = "1" ]; then
        state_write_status cancelled 'Task cancelled'
        return 130
    fi

    # --- validating_result ---
    state_set_phase validating_result 'Validating speed test result'
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

    CFST_LAST_TESTED="$(runner_build_tested_json "$best" "$hostname")"
    state_save_persistent
    cfst_log info "qualified result saved ip=$(runner_json_field "$best" ip)"

    if [ "$mode" = "test-only" ]; then
        state_success 'Speed test completed'
        cfst_log info 'phase=success test-only'
        return 0
    fi

    # --- updating_dns ---
    if [ -z "$hostname" ]; then
        runner_fail NAMING_UNRESOLVED '测速成功，但无法确定 DNS 主机名' 40
        return 40
    fi

    state_set_phase updating_dns 'Updating Cloudflare DNS'
    cfst_log info "phase=updating_dns hostname=$hostname"
    ip="$(runner_json_field "$best" ip)"

    # Preserve prior publication on failure
    prior_published="${CFST_LAST_PUBLISHED:-}"

    set +e
    cf_sync_dns "$hostname" "$ip"
    dns_status=$?
    set -e

    if [ "$dns_status" -eq 0 ]; then
        CFST_LAST_PUBLISHED="$(runner_build_published_json "$best" "$hostname")"
        state_save_persistent
        state_success 'Published DNS record'
        cfst_log info 'phase=success dns published'
        return 0
    fi

    if [ "$dns_status" -eq 66 ]; then
        # New record published; cleanup failed
        CFST_LAST_PUBLISHED="$(runner_build_published_json "$best" "$hostname")"
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
