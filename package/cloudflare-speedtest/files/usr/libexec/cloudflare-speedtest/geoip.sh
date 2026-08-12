#!/bin/sh
# shellcheck disable=SC2034
# GeoIP provider adapters and public IPv4 validation (BusyBox ash).

: "${CFST_GEO_TIMEOUT:=8}"
: "${CFST_GEO_CACHE_TTL_HOURS:=72}"
# Prefer ipwho.is first: ipapi.co is frequently blocked by Cloudflare challenge pages.
: "${CFST_GEO_PROVIDERS:=ipwho.is ipapi.co}"
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

# Normalize ipapi.co (and ipapi.com-compatible) JSON body to identity JSON.
# Contract: fields ip, city, org (ISP). Source label is always ipapi.co.
parse_ipapi() {
    file="$1"
    [ -f "$file" ] || return 1

    ip="$(_json_get "$file" '@.ip')"
    city="$(_json_get "$file" '@.city')"
    isp="$(_json_get "$file" '@.org')"
    # Some ipapi responses use "error":true
    err="$(_json_get "$file" '@.error')"
    if [ "$err" = "true" ] || [ -z "$ip" ] || [ -z "$city" ] || [ -z "$isp" ]; then
        return 1
    fi

    escaped_ip="$(json_escape "$ip")"
    escaped_city="$(json_escape "$city")"
    escaped_isp="$(json_escape "$isp")"
    printf '{"ip":"%s","city":"%s","isp":"%s","source":"ipapi.co"}\n' \
        "$escaped_ip" "$escaped_city" "$escaped_isp"
}

# Normalize ipwho.is JSON body.
# Prefer connection.org over connection.isp: some responses put a street
# address in isp and the real carrier name in org (e.g. CHINANET ...).
parse_ipwhois() {
    file="$1"
    [ -f "$file" ] || return 1

    success="$(_json_get "$file" '@.success')"
    ip="$(_json_get "$file" '@.ip')"
    city="$(_json_get "$file" '@.city')"
    org="$(_json_get "$file" '@.connection.org')"
    isp_field="$(_json_get "$file" '@.connection.isp')"
    # Prefer org when isp is empty or looks like a postal/street address.
    case "$isp_field" in
        ''|*,*|No.*|*[Nn]o\.[0-9]*|*[Ss]treet*|*[Rr]oad*|*[Aa]venue*)
            if [ -n "$org" ]; then
                isp="$org"
            else
                isp="$isp_field"
            fi
            ;;
        *)
            isp="$isp_field"
            [ -n "$isp" ] || isp="$org"
            ;;
    esac
    if [ "$success" = "false" ] || [ -z "$ip" ] || [ -z "$city" ] || [ -z "$isp" ]; then
        return 1
    fi

    escaped_ip="$(json_escape "$ip")"
    escaped_city="$(json_escape "$city")"
    escaped_isp="$(json_escape "$isp")"
    printf '{"ip":"%s","city":"%s","isp":"%s","source":"ipwho.is"}\n' \
        "$escaped_ip" "$escaped_city" "$escaped_isp"
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

query_geo_provider() {
    provider="$1"
    body_file="${CFST_TASK_DIR:-/tmp}/geo-body.$$"
    mkdir -p "${CFST_TASK_DIR:-/tmp}" 2>/dev/null || true

    case "$provider" in
        ipapi.co|ipapi)
            url='https://ipapi.co/json/'
            if ! _geo_curl "$url" "$body_file"; then
                rm -f "$body_file"
                return 1
            fi
            parse_ipapi "$body_file"
            status=$?
            rm -f "$body_file"
            return "$status"
            ;;
        ipwho.is|ipwhois|ipwhois.io)
            url='https://ipwho.is/'
            if ! _geo_curl "$url" "$body_file"; then
                rm -f "$body_file"
                return 1
            fi
            parse_ipwhois "$body_file"
            status=$?
            rm -f "$body_file"
            return "$status"
            ;;
        *)
            return 1
            ;;
    esac
}

_geo_field() {
    json="$1"
    field="$2"
    jsonfilter -s "$json" -e "@.$field" 2>/dev/null || true
}

_cache_is_fresh() {
    cache_json="$1"
    [ -n "$cache_json" ] || return 1
    cached_at="$(_geo_field "$cache_json" cached_at)"
    case "$cached_at" in
        ''|*[!0-9]*) return 1 ;;
    esac
    now="$(cfst_now 2>/dev/null || date +%s)"
    case "$now" in
        ''|*[!0-9]*) now="$(date +%s)" ;;
    esac
    ttl_hours="${CFST_GEO_CACHE_TTL_HOURS:-72}"
    case "$ttl_hours" in
        ''|*[!0-9]*) ttl_hours=72 ;;
    esac
    ttl_seconds=$((ttl_hours * 3600))
    age=$((now - cached_at))
    [ "$age" -ge 0 ] && [ "$age" -le "$ttl_seconds" ]
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

    if [ "${CFST_AUTO_DETECT:-1}" = "1" ]; then
        for provider in $CFST_GEO_PROVIDERS; do
            raw="$(query_geo_provider "$provider" 2>/dev/null)" || raw=''
            [ -n "$raw" ] || continue

            raw_ip="$(_geo_field "$raw" ip)"
            raw_city="$(_geo_field "$raw" city)"
            raw_isp="$(_geo_field "$raw" isp)"
            raw_source="$(_geo_field "$raw" source)"

            if ! validate_public_ipv4 "$raw_ip"; then
                continue
            fi

            mapped_city="$(map_city "$raw_city" 2>/dev/null || true)"
            mapped_isp="$(map_isp "$raw_isp" 2>/dev/null || true)"
            # Keep raw mapped codes even if one side is empty; choose_location_field fills gaps.
            auto_ip="$raw_ip"
            auto_city="$mapped_city"
            auto_isp="$mapped_isp"
            auto_source="$raw_source"
            break
        done
    fi

    cache_json="${CFST_GEO_CACHE:-}"
    cached_city=''
    cached_isp=''
    cached_ip=''
    if _cache_is_fresh "$cache_json"; then
        cached_city="$(_geo_field "$cache_json" city)"
        cached_isp="$(_geo_field "$cache_json" isp)"
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

    printf '{"ip":"%s","city":"%s","isp":"%s","source":"%s"}\n' \
        "$escaped_ip" "$escaped_city" "$escaped_isp" "$escaped_source"
}
