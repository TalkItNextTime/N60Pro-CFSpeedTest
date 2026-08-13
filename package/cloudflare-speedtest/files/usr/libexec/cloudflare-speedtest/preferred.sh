#!/bin/sh
# Preferred reverse-proxy IP source adapters.
# Provider endpoints return one IPv4 address per line, commonly followed by a
# comment after '#'. Only public IPv4 addresses are passed to CFST.

: "${CFST_PREFERRED_URL_CT:=https://cf.090227.xyz/ct?ips=20}"
: "${CFST_PREFERRED_URL_CU:=https://cf.090227.xyz/cu?ips=20}"
: "${CFST_PREFERRED_URL_CMCC:=https://cf.090227.xyz/cmcc?ips=20}"
: "${CFST_PREFERRED_URL_CUSTOM:=}"
: "${CFST_PREFERRED_TIMEOUT:=15}"

preferred_json_field() {
    jsonfilter -s "$1" -e "@.$2" 2>/dev/null || true
}

preferred_provider_from_identity() {
    identity="${1:-}"
    isp="$(preferred_json_field "$identity" isp)"
    case "$isp" in
        ct|cu|cm|cmcc) printf '%s\n' "$isp"; return 0 ;;
    esac
    case "$isp" in
        *电信*|*Telecom*|*telecom*|*CHINANET*|*Chinanet*|*ChinaNet*) printf '%s\n' ct ;;
        *联通*|*Unicom*|*UNICOM*|*CUCC*) printf '%s\n' cu ;;
        *移动*|*Mobile*|*MOBILE*|*CMNET*|*CMCC*) printf '%s\n' cmcc ;;
        *) return 1 ;;
    esac
}

preferred_provider_url() {
    provider="$1"
    case "$provider" in
        ct) printf '%s\n' "$CFST_PREFERRED_URL_CT" ;;
        cu) printf '%s\n' "$CFST_PREFERRED_URL_CU" ;;
        cm|cmcc) printf '%s\n' "$CFST_PREFERRED_URL_CMCC" ;;
        custom) printf '%s\n' "$CFST_PREFERRED_URL_CUSTOM" ;;
        *) return 1 ;;
    esac
}

preferred_select_provider() {
    identity="${1:-}"
    requested="${CFST_PREFERRED_PROVIDER:-auto}"
    case "$requested" in
        ct|cu|cmcc|custom) provider="$requested" ;;
        auto)
            provider="$(preferred_provider_from_identity "$identity" 2>/dev/null || true)"
            if [ -z "$provider" ]; then
                fallback_isp="${CFST_ISP_OVERRIDE:-${CFST_FALLBACK_ISP:-}}"
                case "$fallback_isp" in
                    ct|cu|cm|cmcc) provider="$fallback_isp" ;;
                esac
            fi
            ;;
        *) return 1 ;;
    esac
    [ -n "$provider" ] || return 1
    url="$(preferred_provider_url "$provider" 2>/dev/null || true)"
    case "$url" in http://*|https://*) ;; *) return 1 ;; esac
    CFST_PREFERRED_SELECTED_PROVIDER="$provider"
    CFST_PREFERRED_SELECTED_URL="$url"
    export CFST_PREFERRED_SELECTED_PROVIDER CFST_PREFERRED_SELECTED_URL
    printf '%s\n' "$provider"
}

preferred_fetch_url() {
    url="$1"
    body="$2"
    timeout="${CFST_PREFERRED_TIMEOUT:-15}"
    case "$timeout" in ''|*[!0-9]*) timeout=15 ;; esac
    attempts=1
    delay=1
    while [ "$attempts" -le 3 ]; do
        if (
            unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
            curl --noproxy '*' --fail --silent --show-error \
                --connect-timeout "$timeout" --max-time "$timeout" \
                --output "$body" --url "$url"
        ); then
            return 0
        fi
        rm -f "$body"
        [ "$attempts" -lt 3 ] || break
        "${CFST_SLEEP_CMD:-sleep}" "$delay"
        attempts=$((attempts + 1))
    done
    return 1
}

preferred_extract_ips() {
    src="$1"
    dest="$2"
    [ -f "$src" ] || return 1
    temporary="${dest}.raw.$$"
    awk '
        {
            sub(/\r$/, "")
            ip = $1
            sub(/#.*/, "", ip)
            sub(/,.*/, "", ip)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", ip)
            if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print ip
        }
    ' "$src" | sort -u > "$temporary"
    : > "$dest"
    while IFS= read -r ip || [ -n "$ip" ]; do
        [ -n "$ip" ] || continue
        if validate_public_ipv4 "$ip"; then
            printf '%s\n' "$ip" >> "$dest"
        fi
    done < "$temporary"
    rm -f "$temporary"
    [ -s "$dest" ]
}

# preferred_prepare_ip_file IDENTITY DEST
preferred_prepare_ip_file() {
    identity="${1:-}"
    dest="$2"
    if ! preferred_select_provider "$identity" >/dev/null 2>&1; then
        CFST_ERROR_CODE='PREFERRED_PROVIDER_UNRESOLVED'
        CFST_ERROR_MESSAGE='无法根据本地运营商选择优选反代地址'
        return 1
    fi
    provider="$CFST_PREFERRED_SELECTED_PROVIDER"
    url="$CFST_PREFERRED_SELECTED_URL"
    body="${CFST_TASK_DIR:-/tmp}/preferred-body.$$"
    rm -f "$body" "$dest"
    if ! preferred_fetch_url "$url" "$body"; then
        rm -f "$body"
        CFST_ERROR_CODE='PREFERRED_URL_FETCH_FAILED'
        CFST_ERROR_MESSAGE="优选反代地址请求失败 provider=$provider"
        return 1
    fi
    if ! preferred_extract_ips "$body" "$dest"; then
        rm -f "$body" "$dest"
        CFST_ERROR_CODE='PREFERRED_IPS_EMPTY'
        CFST_ERROR_MESSAGE="优选反代地址未返回可用 IPv4 provider=$provider"
        return 1
    fi
    rm -f "$body"
    CFST_PREFERRED_SELECTED_COUNT="$(wc -l < "$dest" | tr -d ' ')"
    export CFST_PREFERRED_SELECTED_COUNT
    return 0
}
