#!/bin/sh
# shellcheck disable=SC2034
# CFST CSV validation and best-candidate selection (BusyBox ash).
#
# Upstream CSV contract: fields are simple/numeric and do not contain quoted
# commas. Rows are parsed with awk -F, only; do not introduce a full CSV parser.

: "${CFST_TASK_DIR:=/tmp/cloudflare-speedtest}"

CFST_CSV_HEADER='IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码'

set_result_error() {
    CFST_ERROR_CODE="$1"
    CFST_ERROR_MESSAGE="$2"
    return "${3:-50}"
}

# True for public unicast IPv4 suitable as a CFST candidate.
# Rejects private, loopback, link-local, multicast, 0.0.0.0/8, and TEST-NET.
is_ipv4() {
    ip="$1"
    case "$ip" in
        ''|*[!0-9.]*) return 1 ;;
    esac

    printf '%s\n' "$ip" | awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || length($i) > 3) exit 1
                if (length($i) > 1 && substr($i, 1, 1) == "0") exit 1
                n = $i + 0
                if (n < 0 || n > 255) exit 1
                o[i] = n
            }
            if (o[1] == 0) exit 1
            if (o[1] == 127) exit 1
            if (o[1] == 10) exit 1
            if (o[1] == 172 && o[2] >= 16 && o[2] <= 31) exit 1
            if (o[1] == 192 && o[2] == 168) exit 1
            if (o[1] == 169 && o[2] == 254) exit 1
            if (o[1] >= 224) exit 1
            if (o[1] == 192 && o[2] == 0 && o[3] == 2) exit 1
            if (o[1] == 198 && o[2] == 51 && o[3] == 100) exit 1
            if (o[1] == 203 && o[2] == 0 && o[3] == 113) exit 1
            exit 0
        }
    '
}

_is_number() {
    case "$1" in
        ''|*[!0-9.]*) return 1 ;;
    esac
    awk -v value="$1" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/) }'
}

_number_le() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 <= b + 0) }'
}

_number_ge() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'
}

_number_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'
}

# Strip a UTF-8 BOM from the first line only and compare to the expected header.
validate_cfst_header() {
    file="$1"
    CFST_ERROR_CODE=''
    CFST_ERROR_MESSAGE=''

    [ -f "$file" ] || {
        set_result_error RESULT_BAD_CSV '测速结果文件不存在' 50
        return $?
    }

    header="$(awk 'NR==1 {
        sub(/^\xef\xbb\xbf/, "")
        sub(/\r$/, "")
        print
        exit
    }' "$file")"

    if [ "$header" != "$CFST_CSV_HEADER" ]; then
        set_result_error RESULT_BAD_CSV '测速结果表头不匹配' 50
        return $?
    fi
    return 0
}

# candidate_is_qualified IP SENT RECV LOSS LATENCY SPEED_MB_S MAX_LATENCY MAX_LOSS MIN_SPEED_MBPS
candidate_is_qualified() {
    ip="$1"
    sent="$2"
    recv="$3"
    loss="$4"
    latency="$5"
    speed="$6"
    max_latency="$7"
    max_loss="$8"
    min_speed="$9"

    is_ipv4 "$ip" || return 1
    _is_number "$sent" || return 1
    _is_number "$recv" || return 1
    _is_number "$loss" || return 1
    _is_number "$latency" || return 1
    _is_number "$speed" || return 1
    _is_number "$max_latency" || return 1
    _is_number "$max_loss" || return 1
    _is_number "$min_speed" || return 1

    # received packets must be > 0
    _number_gt "$recv" 0 || return 1
    # latency > 0 and <= max
    _number_gt "$latency" 0 || return 1
    _number_le "$latency" "$max_latency" || return 1
    # loss in [0, max_loss]
    _number_ge "$loss" 0 || return 1
    _number_le "$loss" "$max_loss" || return 1
    # CFST CSV reports MB/s, while the plugin setting is Mbps.
    # Convert the configured threshold to the CSV unit before comparing.
    _number_ge "$speed" 0 || return 1
    min_speed_mb_s="$(awk -v mbps="$min_speed" 'BEGIN { printf "%.10f", mbps / 8 }')"
    _number_ge "$speed" "$min_speed_mb_s" || return 1
    return 0
}

_normalize_number() {
    awk -v value="$1" 'BEGIN {
        if (value ~ /^[0-9]+$/) {
            printf "%s", value
        } else {
            # trim trailing zeros after decimal while keeping meaningful form
            n = value + 0
            s = sprintf("%.10f", n)
            sub(/0+$/, "", s)
            sub(/\.$/, "", s)
            printf "%s", s
        }
    }'
}

# result_has_qualified_latency FILE MAX_LATENCY MAX_LOSS
# Returns success when the CSV contains at least one candidate that passed the
# latency/loss gate. This intentionally ignores download speed: it is used by
# the adaptive preflight before the real download phase.
result_has_qualified_latency() {
    file="$1"
    max_latency="$2"
    max_loss="$3"
    validate_cfst_header "$file" >/dev/null 2>&1 || return 1
    awk -F, -v max_latency="$max_latency" -v max_loss="$max_loss" '
        NR == 1 { next }
        function is_num(v) { return v ~ /^[0-9]+([.][0-9]+)?$/ }
        {
            sub(/\r$/, "", $0)
            if (NF != 7) next
            if (!is_num($2) || !is_num($3) || !is_num($4) || !is_num($5)) next
            if ($3 + 0 <= 0) next
            if ($5 + 0 <= 0 || $5 + 0 > max_latency + 0) next
            if ($4 + 0 < 0 || $4 + 0 > max_loss + 0) next
            found = 1
            exit
        }
        END { exit(found ? 0 : 1) }
    ' "$file"
}

_CFST_AWK_IS_PUBLIC_IPV4='
    function is_public_ipv4(ip,   n, a, i) {
        n = split(ip, a, ".")
        if (n != 4) return 0
        for (i = 1; i <= 4; i++) {
            if (a[i] !~ /^[0-9]+$/ || length(a[i]) > 3) return 0
            if (length(a[i]) > 1 && substr(a[i], 1, 1) == "0") return 0
            if (a[i] + 0 > 255) return 0
        }
        if (a[1] + 0 == 0) return 0
        if (a[1] + 0 == 127) return 0
        if (a[1] + 0 == 10) return 0
        if (a[1] + 0 == 172 && a[2] + 0 >= 16 && a[2] + 0 <= 31) return 0
        if (a[1] + 0 == 192 && a[2] + 0 == 168) return 0
        if (a[1] + 0 == 169 && a[2] + 0 == 254) return 0
        if (a[1] + 0 >= 224) return 0
        if (a[1] + 0 == 192 && a[2] + 0 == 0 && a[3] + 0 == 2) return 0
        if (a[1] + 0 == 198 && a[2] + 0 == 51 && a[3] + 0 == 100) return 0
        if (a[1] + 0 == 203 && a[2] + 0 == 0 && a[3] + 0 == 113) return 0
        return 1
    }
'

# result_reject_summary FILE MAX_LATENCY MAX_LOSS MIN_SPEED_MBPS
# One-line breakdown of how the CSV rows scored against each gate. Logged when
# selection finds nothing so the log alone shows which gate emptied the set.
result_reject_summary() {
    file="$1"
    max_latency="$2"
    max_loss="$3"
    min_speed="$4"
    if [ ! -f "$file" ]; then
        printf 'rows=0 csv=missing'
        return 0
    fi
    awk -F, -v max_latency="$max_latency" -v max_loss="$max_loss" -v min_speed_mbps="$min_speed" "
        function is_num(v) { return v ~ /^[0-9]+([.][0-9]+)?\$/ }
        $_CFST_AWK_IS_PUBLIC_IPV4"'
        NR == 1 { next }
        {
            sub(/\r$/, "", $0)
            if ($0 == "") next
            rows++
            if (NF != 7 || !is_num($3) || !is_num($4) || !is_num($5) || !is_num($6)) { malformed++; next }
            if (!is_public_ipv4($1)) { nonpublic++; next }
            if ($3 + 0 <= 0 || $4 + 0 < 0 || $4 + 0 > max_loss + 0) { loss_rejected++; next }
            if ($5 + 0 <= 0 || $5 + 0 > max_latency + 0) { latency_rejected++; next }
            gate_ok++
            if ($6 + 0 > best_speed) best_speed = $6 + 0
        }
        END {
            printf "rows=%d malformed=%d nonpublic=%d loss_rejected=%d latency_rejected=%d latency_loss_ok=%d max_speed_mbps=%.3f required_mbps=%s",
                rows, malformed, nonpublic, loss_rejected, latency_rejected, gate_ok, best_speed * 8, min_speed_mbps
        }
    ' "$file"
}

# result_qualified_ips FILE MAX_LATENCY MAX_LOSS
# Prints the public IPv4 addresses that passed the latency/loss gate, one per
# line, in the order the CSV lists them (cfst writes it latency-ascending).
# The download pass uses this to re-measure only the addresses the preflight
# already proved reachable; re-testing the whole sample doubles the latency
# phase, which is the dominant cost once measurements are real.
result_qualified_ips() {
    file="$1"
    max_latency="$2"
    max_loss="$3"
    [ -f "$file" ] || return 1
    awk -F, -v max_latency="$max_latency" -v max_loss="$max_loss" "
        function is_num(v) { return v ~ /^[0-9]+([.][0-9]+)?\$/ }
        $_CFST_AWK_IS_PUBLIC_IPV4"'
        NR == 1 { next }
        {
            sub(/\r$/, "", $0)
            if (NF != 7) next
            if (!is_public_ipv4($1)) next
            if (!is_num($3) || !is_num($4) || !is_num($5)) next
            if ($3 + 0 <= 0) next
            if ($5 + 0 <= 0 || $5 + 0 > max_latency + 0) next
            if ($4 + 0 < 0 || $4 + 0 > max_loss + 0) next
            if (seen[$1]++) next
            print $1
        }
    ' "$file"
}

# result_merge_csv OUT FIRST [SECOND ...]
# Writes one CSV_HEADER line followed by the data rows of every readable input,
# deduplicated by IP keeping the row with the highest speed. Missing or empty
# inputs are skipped. Always exits 0 as long as OUT could be written.
result_merge_csv() {
    out="$1"
    shift
    printf '%s\n' "$CFST_CSV_HEADER" > "$out" || return 1
    for source_file in "$@"; do
        [ -s "$source_file" ] || continue
        awk -F, 'NR > 1 { sub(/\r$/, "", $0); if (NF == 7 && $1 != "") print }' "$source_file"
    done | awk -F, '
        {
            if (!($1 in best) || $6 + 0 > speed[$1] + 0) {
                best[$1] = $0
                speed[$1] = $6
                if (!($1 in seen)) { order[++n] = $1; seen[$1] = 1 }
            }
        }
        END { for (i = 1; i <= n; i++) print best[order[i]] }
    ' >> "$out"
}

# select_best_result FILE MAX_LATENCY MAX_LOSS MIN_SPEED [STICKY_IP] [MARGIN_PCT]
# Prints one compact JSON object for the best qualified candidate. Candidates
# are scored on download speed and latency together, each normalised against the
# best value in the qualified set, so the winner is the best compromise rather
# than the raw fastest — a burst-speed winner three timezones away loses to a
# nearby node that is only slightly slower. SPEED_WEIGHT is that split as a
# percentage; latency takes the remainder. When STICKY_IP is qualified it is
# retained unless another candidate exceeds its score by more than MARGIN_PCT.
# Exit 50 RESULT_BAD_CSV or 51 RESULT_NO_QUALIFIED_IP on failure.
select_best_result() {
    file="$1"
    max_latency="$2"
    max_loss="$3"
    min_speed="$4"
    sticky_ip="${5:-}"
    margin_pct="${6:-0}"
    speed_weight="${7:-60}"

    CFST_ERROR_CODE=''
    CFST_ERROR_MESSAGE=''

    validate_cfst_header "$file"
    header_status=$?
    if [ "$header_status" -ne 0 ]; then
        return "$header_status"
    fi

    # Skip header; contract: simple comma fields, no quoted commas.
    # The upstream CSV speed column is MB/s. The plugin setting is Mbps, so
    # compare against min_speed / 8 and expose the selected value as Mbps.
    # Ranking happens here rather than via sort: BusyBox sort on some OpenWrt
    # builds silently ignores -t/-k and falls back to whole-line lexicographic
    # order, which picked the lowest-numbered IP instead of the fastest.
    best="$(awk -F, -v max_latency="$max_latency" -v max_loss="$max_loss" -v min_speed_mbps="$min_speed" \
        -v sticky_ip="$sticky_ip" -v margin_pct="$margin_pct" -v speed_weight="$speed_weight" "
        function is_num(v) { return v ~ /^[0-9]+([.][0-9]+)?\$/ }
        $_CFST_AWK_IS_PUBLIC_IPV4"'
        NR == 1 { next }
        {
            sub(/\r$/, "", $0)
            if (NF != 7) next
            ip = $1
            sent = $2
            recv = $3
            loss = $4
            latency = $5
            speed = $6
            colo = $7
            if (!is_public_ipv4(ip)) next
            if (!is_num(sent) || !is_num(recv) || !is_num(loss) || !is_num(latency) || !is_num(speed)) next
            if (recv + 0 <= 0) next
            if (latency + 0 <= 0 || latency + 0 > max_latency + 0) next
            if (loss + 0 < 0 || loss + 0 > max_loss + 0) next
            if (speed + 0 < 0 || speed + 0 < (min_speed_mbps + 0) / 8) next
            # Collect first, score in END: both normalisers need the whole set.
            n++
            r_ip[n] = ip
            r_loss[n] = loss
            r_latency[n] = latency
            r_speed[n] = speed
            r_colo[n] = colo
            if (speed + 0 > top_speed) top_speed = speed + 0
            if (low_latency == 0 || latency + 0 < low_latency) low_latency = latency + 0
        }
        END {
            if (n == 0) exit
            ws = (speed_weight + 0) / 100
            if (ws < 0) ws = 0
            if (ws > 1) ws = 1
            wl = 1 - ws
            best_i = 0
            sticky_i = 0
            for (i = 1; i <= n; i++) {
                speed_part = (top_speed > 0) ? (r_speed[i] + 0) / top_speed : 0
                latency_part = (low_latency > 0) ? low_latency / (r_latency[i] + 0) : 0
                score[i] = speed_part * ws + latency_part * wl
                if (best_i == 0) better = 1
                else if (score[i] > score[best_i]) better = 1
                else if (score[i] == score[best_i]) {
                    if (r_latency[i] + 0 < r_latency[best_i] + 0) better = 1
                    else if (r_latency[i] + 0 == r_latency[best_i] + 0 &&
                             r_loss[i] + 0 < r_loss[best_i] + 0) better = 1
                    else better = 0
                }
                else better = 0
                if (better) best_i = i
                if (sticky_ip != "" && r_ip[i] == sticky_ip) sticky_i = i
            }
            # Keep the currently published IP unless a candidate scores higher
            # by more than the configured margin. Measurements carry enough
            # noise that always taking the maximum churns the DNS record.
            if (sticky_i > 0 && best_i != sticky_i &&
                score[best_i] <= score[sticky_i] * (1 + (margin_pct + 0) / 100)) {
                best_i = sticky_i
            }
            printf "%s,%s,%s,%s,%s\n", r_ip[best_i], r_loss[best_i], r_latency[best_i], r_speed[best_i], r_colo[best_i]
        }
    ' "$file")"

    if [ -z "$best" ]; then
        set_result_error RESULT_NO_QUALIFIED_IP '没有符合条件的测速结果' 51
        return $?
    fi

    ip="$(printf '%s\n' "$best" | awk -F, '{print $1}')"
    loss="$(printf '%s\n' "$best" | awk -F, '{print $2}')"
    latency="$(printf '%s\n' "$best" | awk -F, '{print $3}')"
    speed="$(printf '%s\n' "$best" | awk -F, '{print $4}')"
    colo="$(printf '%s\n' "$best" | awk -F, '{print $5}')"

    loss_out="$(_normalize_number "$loss")"
    latency_out="$(_normalize_number "$latency")"
    # Upstream writes MB/s; keep the plugin/API contract in Mbps.
    speed_out="$(_normalize_number "$(awk -v mbps="$speed" 'BEGIN { printf "%.10f", mbps * 8 }')")"

    escaped_ip="$(json_escape "$ip")"
    escaped_colo="$(json_escape "$colo")"

    printf '{"ip":"%s","latency_ms":%s,"loss_ratio":%s,"speed_mbps":%s,"colo":"%s"}\n' \
        "$escaped_ip" "$latency_out" "$loss_out" "$speed_out" "$escaped_colo"
}
