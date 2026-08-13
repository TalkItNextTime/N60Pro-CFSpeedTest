#!/bin/sh
# shellcheck disable=SC2034
# GeoIP provider adapters and public IPv4 validation (BusyBox ash).

: "${CFST_GEO_TIMEOUT:=8}"
: "${CFST_NETWORK_CACHE_TTL_DAYS:=7}"
: "${CFST_IPINFO_CACHE_TTL_DAYS:=30}"
: "${CFST_IPINFO_CLEANUP_HOURS:=6}"
: "${CFST_IPINFO_CACHE_DIR:=/etc/cloudflare-speedtest/ipinfo-cache}"
: "${CFST_IPINFO_CLEANUP_STAMP_FILE:=$CFST_IPINFO_CACHE_DIR/.last_cleanup}"
: "${CFST_TASK_DIR:=/tmp/cloudflare-speedtest}"

set_geo_error() {
    CFST_ERROR_CODE="$1"
    CFST_ERROR_MESSAGE="$2"
    return "${3:-41}"
}

# Validate a dotted-quad public unicast IPv4.
# Rejects private, loopback, link-local, multicast, 0.0.0.0/8,
# and documentation ranges (TEST-NET-1/2/3).
validate_public_ipv4() {
    ip="$1"
    case "$ip" in
        ''|*[!0-9.]*) return 1 ;;
    esac

    printf '%s\n' "$ip" | awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || length($i) > 3) exit 1
                # no leading zeros unless the octet is exactly "0"
                if (length($i) > 1 && substr($i, 1, 1) == "0") exit 1
                n = $i + 0
                if (n < 0 || n > 255) exit 1
                o[i] = n
            }
            # 0.0.0.0/8
            if (o[1] == 0) exit 1
            # loopback 127.0.0.0/8
            if (o[1] == 127) exit 1
            # private 10.0.0.0/8
            if (o[1] == 10) exit 1
            # private 172.16.0.0/12
            if (o[1] == 172 && o[2] >= 16 && o[2] <= 31) exit 1
            # private 192.168.0.0/16
            if (o[1] == 192 && o[2] == 168) exit 1
            # link-local 169.254.0.0/16
            if (o[1] == 169 && o[2] == 254) exit 1
            # multicast 224.0.0.0/4 and reserved 240.0.0.0/4
            if (o[1] >= 224) exit 1
            # documentation TEST-NET-1 192.0.2.0/24
            if (o[1] == 192 && o[2] == 0 && o[3] == 2) exit 1
            # documentation TEST-NET-2 198.51.100.0/24
            if (o[1] == 198 && o[2] == 51 && o[3] == 100) exit 1
            # documentation TEST-NET-3 203.0.113.0/24
            if (o[1] == 203 && o[2] == 0 && o[3] == 113) exit 1
            exit 0
        }
    '
}

_json_get() {
    file="$1"
    expr="$2"
    jsonfilter -i "$file" -e "$expr" 2>/dev/null || true
}

# UAPIS returns a region string such as "China Guangdong Shenzhen". Keep the complete
# region for display and use the final token for the city-code mapping.
parse_uapi_network() {
    file="$1"
    [ -f "$file" ] || return 1
    ip="$(_json_get "$file" '@.ip')"
    region="$(_json_get "$file" '@.region')"
    isp="$(_json_get "$file" '@.isp')"
    asn="$(_json_get "$file" '@.asn')"
    llc="$(_json_get "$file" '@.llc')"
    [ -n "$ip" ] && [ -n "$region" ] && [ -n "$isp" ] || return 1
    city="$(printf '%s\n' "$region" | awk '{print $NF}')"
    [ -n "$city" ] || return 1
    printf '{"ip":"%s","region":"%s","city":"%s","isp":"%s","asn":"%s","llc":"%s","source":"uapis.cn"}\n' \
        "$(json_escape "$ip")" "$(json_escape "$region")" "$(json_escape "$city")" \
        "$(json_escape "$isp")" "$(json_escape "$asn")" "$(json_escape "$llc")"
}

parse_uapi_ipinfo() {
    file="$1"
    parsed="$(parse_uapi_network "$file" 2>/dev/null)" || return 1
    printf '%s\n' "$parsed" | sed 's/"source":"uapis.cn"/"source":"uapis.cn\/ipinfo"/'
}

# Fetch a provider URL into outfile using curl with proxy bypass.
# Does not inherit http_proxy/https_proxy/all_proxy (any case).
_geo_curl() {
    url="$1"
    outfile="$2"
    timeout="${CFST_GEO_TIMEOUT:-8}"

    # BusyBox env may lack -u; clear proxy vars in a subshell instead.
    (
        unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
        curl --noproxy '*' \
            --fail-with-body \
            --silent \
            --show-error \
            --connect-timeout "$timeout" \
            --max-time "$timeout" \
            --output "$outfile" \
            --url "$url"
    )
}

query_myip() {
    body_file="${CFST_TASK_DIR:-/tmp}/myip-body.$$"
    mkdir -p "${CFST_TASK_DIR:-/tmp}" 2>/dev/null || true
    if ! _geo_curl 'https://uapis.cn/api/v1/network/myip' "$body_file"; then
        rm -f "$body_file"
        return 1
    fi
    parse_uapi_network "$body_file"
    status=$?
    rm -f "$body_file"
    return "$status"
}

_geo_field() {
    json="$1"
    field="$2"
    jsonfilter -s "$json" -e "@.$field" 2>/dev/null || true
}

_network_cache_is_fresh() {
    cache_json="$1"
    queried_at="$(_geo_field "$cache_json" queried_at)"
    case "$queried_at" in ''|*[!0-9]*) return 1 ;; esac
    now="$(cfst_now 2>/dev/null || date +%s)"
    ttl_days="${CFST_NETWORK_CACHE_TTL_DAYS:-7}"
    case "$ttl_days" in ''|*[!0-9]*) ttl_days=7 ;; esac
    age=$((now - queried_at))
    [ "$age" -ge 0 ] && [ "$age" -le $((ttl_days * 86400)) ]
}

ipinfo_cache_file() {
    ip="$1"
    validate_public_ipv4 "$ip" || return 1
    mkdir -p "$CFST_IPINFO_CACHE_DIR" 2>/dev/null || return 1
    printf '%s/%s.json\n' "$CFST_IPINFO_CACHE_DIR" "$(printf '%s' "$ip" | tr . _)"
}

_ipinfo_cache_is_fresh() {
    cache_json="$1"
    queried_at="$(_geo_field "$cache_json" queried_at)"
    case "$queried_at" in ''|*[!0-9]*) return 1 ;; esac
    now="$(cfst_now 2>/dev/null || date +%s)"
    ttl_days="${CFST_IPINFO_CACHE_TTL_DAYS:-30}"
    case "$ttl_days" in ''|*[!0-9]*) ttl_days=30 ;; esac
    age=$((now - queried_at))
    [ "$age" -ge 0 ] && [ "$age" -le $((ttl_days * 86400)) ]
}

query_ipinfo() {
    ip="$1"
    validate_public_ipv4 "$ip" || return 1
    body_file="${CFST_TASK_DIR:-/tmp}/ipinfo-body.$$"
    if ! _geo_curl "https://uapis.cn/api/v1/network/ipinfo?ip=$ip" "$body_file"; then
        rm -f "$body_file"
        return 1
    fi
    parsed="$(parse_uapi_ipinfo "$body_file" 2>/dev/null)"
    status=$?
    rm -f "$body_file"
    [ "$status" -eq 0 ] || return 1
    now="$(cfst_now 2>/dev/null || date +%s)"
    ip_value="$(_geo_field "$parsed" ip)"
    region_value="$(_geo_field "$parsed" region)"
    city_value="$(_geo_field "$parsed" city)"
    isp_value="$(_geo_field "$parsed" isp)"
    asn_value="$(_geo_field "$parsed" asn)"
    llc_value="$(_geo_field "$parsed" llc)"
    source_value="$(_geo_field "$parsed" source)"
    printf '{"ip":"%s","region":"%s","city":"%s","isp":"%s","asn":"%s","llc":"%s","source":"%s","queried_at":%s}\n' \
        "$(json_escape "$ip_value")" "$(json_escape "$region_value")" "$(json_escape "$city_value")" \
        "$(json_escape "$isp_value")" "$(json_escape "$asn_value")" "$(json_escape "$llc_value")" \
        "$(json_escape "$source_value")" "$now"
}

ipinfo_cleanup_if_due() {
    now="$(cfst_now 2>/dev/null || date +%s)"
    last="${CFST_IPINFO_LAST_CLEANUP:-}"
    if [ -z "$last" ] && [ -f "$CFST_IPINFO_CLEANUP_STAMP_FILE" ]; then
        last="$(cat "$CFST_IPINFO_CLEANUP_STAMP_FILE" 2>/dev/null || true)"
    fi
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    hours="${CFST_IPINFO_CLEANUP_HOURS:-6}"
    case "$hours" in ''|*[!0-9]*) hours=6 ;; esac
    if [ $((now - last)) -lt $((hours * 3600)) ] && [ "$last" -le "$now" ]; then return 0; fi
    if [ -d "$CFST_IPINFO_CACHE_DIR" ]; then
        for file in "$CFST_IPINFO_CACHE_DIR"/*.json; do
            [ -f "$file" ] || continue
            cached="$(cat "$file" 2>/dev/null || true)"
            _ipinfo_cache_is_fresh "$cached" || rm -f "$file"
        done
    fi
    mkdir -p "${CFST_IPINFO_CLEANUP_STAMP_FILE%/*}" 2>/dev/null || true
    printf '%s\n' "$now" > "$CFST_IPINFO_CLEANUP_STAMP_FILE" 2>/dev/null || true
    CFST_IPINFO_LAST_CLEANUP="$now"
    export CFST_IPINFO_LAST_CLEANUP
}

ipinfo_get_or_query() {
    ip="$1"
    file="$(ipinfo_cache_file "$ip" 2>/dev/null || true)"
    [ -n "$file" ] || return 1
    cached=""
    [ -f "$file" ] && cached="$(cat "$file" 2>/dev/null || true)"
    if _ipinfo_cache_is_fresh "$cached"; then printf '%s\n' "$cached"; return 0; fi
    info="$(query_ipinfo "$ip" 2>/dev/null || true)"
    [ -n "$info" ] || return 1
    atomic_write "$file" <<EOF
$info
EOF
    printf '%s\n' "$info"
}


_cache_is_fresh() {
    # Backward-compatible name used by the resolver; network_cache uses the
    # UAPIS myip query timestamp and a seven-day TTL.
    _network_cache_is_fresh "$1"
}

_pick_source() {
    if [ -n "${CFST_CITY_OVERRIDE:-}" ] && [ -n "${CFST_ISP_OVERRIDE:-}" ]; then
        printf '%s\n' 'override'
        return 0
    fi
    if [ -n "$auto_source" ] && [ -n "$auto_city" ] && [ -n "$auto_isp" ] \
        && [ -z "${CFST_CITY_OVERRIDE:-}" ] && [ -z "${CFST_ISP_OVERRIDE:-}" ]; then
        printf '%s\n' "$auto_source"
        return 0
    fi
    if [ -n "${CFST_CITY_OVERRIDE:-}" ] || [ -n "${CFST_ISP_OVERRIDE:-}" ]; then
        if [ -n "$auto_city" ] || [ -n "$auto_isp" ]; then
            printf '%s\n' "${auto_source:-override}"
            return 0
        fi
        if [ -n "$cached_city" ] || [ -n "$cached_isp" ]; then
            printf '%s\n' 'cache'
            return 0
        fi
        printf '%s\n' 'override'
        return 0
    fi
    if [ -n "$auto_source" ] && { [ -n "$auto_city" ] || [ -n "$auto_isp" ]; }; then
        printf '%s\n' "$auto_source"
        return 0
    fi
    if [ -n "$cached_city" ] || [ -n "$cached_isp" ]; then
        printf '%s\n' 'cache'
        return 0
    fi
    printf '%s\n' 'fallback'
}

# Resolve city/ISP codes and optional public IP for hostname construction.
# Priority per design: field override > trusted auto result > unexpired cache > fixed fallback.
# Returns JSON: {"ip":"...","city":"sz","isp":"ct","source":"..."}
# Exit 41 / GEO_ALL_PROVIDERS_FAILED when no safe hostname fields can be resolved.
resolve_network_identity() {
    CFST_ERROR_CODE=''
    CFST_ERROR_MESSAGE=''

    auto_ip=''
    auto_city=''
    auto_isp=''
    auto_source=''
    raw_region=''
    raw_asn=''
    raw_llc=''
    raw_queried_at=''

    if [ "${CFST_AUTO_DETECT:-1}" = "1" ]; then
        raw=''
        # The public-IP lookup is deliberately low frequency. A persisted UAPI
        # response is reused for seven days; this also avoids changing the
        # hostname on every speed-test run.
        if [ ! -f "${CFST_NETWORK_CACHE_INVALIDATION_FILE:-/tmp/cloudflare-speedtest/network-cache-invalidated}" ] && _network_cache_is_fresh "${CFST_NETWORK_CACHE:-}"; then
            raw="${CFST_NETWORK_CACHE}"
        else
            raw="$(query_myip 2>/dev/null)" || raw=''
            if [ -n "$raw" ]; then
                # UAPIS myip has no cache timestamp. Attach the query time
                # before persisting it so normal runs reuse this response for
                # seven days and WAN hotplug can explicitly invalidate it.
                now="$(cfst_now 2>/dev/null || date +%s)"
                raw="$(printf '%s\n' "$raw" | sed "s/}$/,$(printf '"queried_at":%s' "$now")}/")"
                CFST_NETWORK_CACHE="$raw"
                export CFST_NETWORK_CACHE
                rm -f "${CFST_NETWORK_CACHE_INVALIDATION_FILE:-/tmp/cloudflare-speedtest/network-cache-invalidated}" 2>/dev/null || true
            fi
        fi
        if [ -n "$raw" ]; then

            raw_ip="$(_geo_field "$raw" ip)"
            raw_city="$(_geo_field "$raw" city)"
            raw_isp="$(_geo_field "$raw" isp)"
            raw_source="$(_geo_field "$raw" source)"
            raw_region="$(_geo_field "$raw" region)"
            raw_asn="$(_geo_field "$raw" asn)"
            raw_llc="$(_geo_field "$raw" llc)"
            raw_queried_at="$(_geo_field "$raw" queried_at)"
            case "$raw_queried_at" in
                ''|*[!0-9]*) raw_queried_at=0 ;;
            esac

            if ! validate_public_ipv4 "$raw_ip"; then
                raw=''
            fi
            if [ -z "$raw" ]; then
                set_geo_error GEO_ALL_PROVIDERS_FAILED 'invalid public IP response' 41
                return $?
            fi

            mapped_city="$(map_city "$raw_city" 2>/dev/null || true)"
            mapped_isp="$(map_isp "$raw_isp" 2>/dev/null || true)"
            # Keep raw mapped codes even if one side is empty; choose_location_field fills gaps.
            auto_ip="$raw_ip"
            auto_city="$mapped_city"
            auto_isp="$mapped_isp"
            auto_source="$raw_source"
        fi
    fi

    # The only remote local-network source is UAPIS myip. Reuse its
    # persisted seven-day cache; do not fall back to another IP provider or
    # to the legacy preferred-node geo cache.
    cache_json="${CFST_NETWORK_CACHE:-}"
    cached_city=''
    cached_isp=''
    cached_ip=''
    if _cache_is_fresh "$cache_json"; then
        cached_city_raw="$(_geo_field "$cache_json" city)"
        cached_isp_raw="$(_geo_field "$cache_json" isp)"
        # Persisted state from older versions may contain Chinese names or
        # provider names instead of normalized codes. Normalize both forms
        # before using them in a {city}/{isp} hostname template.
        cached_city="$(map_city "$cached_city_raw" 2>/dev/null || true)"
        cached_isp="$(map_isp "$cached_isp_raw" 2>/dev/null || true)"
        [ -n "$cached_city" ] || cached_city="$cached_city_raw"
        [ -n "$cached_isp" ] || cached_isp="$cached_isp_raw"
        cached_ip="$(_geo_field "$cache_json" ip)"
    fi

    city_code="$(choose_location_field \
        "${CFST_CITY_OVERRIDE:-}" \
        "$auto_city" \
        "$cached_city" \
        "${CFST_FALLBACK_CITY:-}")"
    isp_code="$(choose_location_field \
        "${CFST_ISP_OVERRIDE:-}" \
        "$auto_isp" \
        "$cached_isp" \
        "${CFST_FALLBACK_ISP:-}")"

    if [ -z "$city_code" ] || [ -z "$isp_code" ]; then
        set_geo_error GEO_ALL_PROVIDERS_FAILED '无法解析可用的城市或运营商标识' 41
        return $?
    fi

    source="$(_pick_source)"

    ip_out="$auto_ip"
    [ -n "$ip_out" ] || ip_out="$cached_ip"

    escaped_ip="$(json_escape "${ip_out:-}")"
    escaped_city="$(json_escape "$city_code")"
    escaped_isp="$(json_escape "$isp_code")"
    escaped_source="$(json_escape "$source")"
    escaped_region="$(json_escape "${raw_region:-}")"
    escaped_asn="$(json_escape "${raw_asn:-}")"
    escaped_llc="$(json_escape "${raw_llc:-}")"
    case "$raw_queried_at" in ''|*[!0-9]*) raw_queried_at=0 ;; esac

    printf '{"ip":"%s","city":"%s","isp":"%s","source":"%s","region":"%s","asn":"%s","llc":"%s","queried_at":%s}\n' \
        "$escaped_ip" "$escaped_city" "$escaped_isp" "$escaped_source" "$escaped_region" "$escaped_asn" "$escaped_llc" "$raw_queried_at"
}
