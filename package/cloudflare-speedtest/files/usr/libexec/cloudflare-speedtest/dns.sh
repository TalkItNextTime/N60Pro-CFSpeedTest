#!/bin/sh
# shellcheck disable=SC2034
# Cloudflare DNS API helpers (BusyBox ash). Token from env/config only.

: "${CFST_CF_API_BASE:=https://api.cloudflare.com/client/v4}"
: "${CFST_TASK_DIR:=/tmp/cloudflare-speedtest}"
: "${CFST_SLEEP_CMD:=sleep}"
: "${CFST_TTL:=1}"

set_dns_error() {
    CFST_ERROR_CODE="$1"
    CFST_ERROR_MESSAGE="$2"
    return "${3:-63}"
}

_cf_json_get() {
    file="$1"
    expr="$2"
    jsonfilter -i "$file" -e "$expr" 2>/dev/null || true
}

_cf_json_get_s() {
    json="$1"
    expr="$2"
    jsonfilter -s "$json" -e "$expr" 2>/dev/null || true
}

_cf_sleep_delay() {
    seconds="$1"
    case "$seconds" in
        ''|*[!0-9]*) seconds=1 ;;
    esac
    if [ "$seconds" -le 0 ]; then
        return 0
    fi
    "${CFST_SLEEP_CMD:-sleep}" "$seconds" 2>/dev/null || true
}

_cf_parse_retry_after() {
    headers_file="$1"
    [ -f "$headers_file" ] || {
        printf '%s' ''
        return 0
    }
    # Last Retry-After wins; allow integer seconds only.
    awk 'BEGIN { IGNORECASE=1 }
        tolower($1) ~ /^retry-after:/ {
            val = $2
            gsub(/\r/, "", val)
            if (val ~ /^[0-9]+$/) last = val
        }
        END { if (last != "") print last }' "$headers_file"
}

_cf_classify_http() {
    status="$1"
    case "$status" in
        401)
            set_dns_error CF_API_UNAUTHORIZED 'Cloudflare API 未授权' 60
            return $?
            ;;
        403)
            set_dns_error CF_API_FORBIDDEN 'Cloudflare API 禁止访问' 61
            return $?
            ;;
        429)
            set_dns_error CF_API_RATE_LIMITED 'Cloudflare API 限流' 62
            return $?
            ;;
        500|502|503|504)
            set_dns_error CF_API_TEMPORARY 'Cloudflare API 暂时不可用' 63
            return $?
            ;;
        *)
            set_dns_error CF_API_TEMPORARY "Cloudflare API HTTP $status" 63
            return $?
            ;;
    esac
}

# cf_api METHOD PATH [BODY]
# Uses CFST_API_TOKEN from environment. Writes under CFST_TASK_DIR.
# Sets CFST_HTTP_STATUS, CFST_CF_BODY_FILE, CFST_CF_HEADERS_FILE.
cf_api() {
    method="$1"
    path="$2"
    body="${3:-}"

    CFST_ERROR_CODE=''
    CFST_ERROR_MESSAGE=''
    CFST_HTTP_STATUS=''

    token="${CFST_API_TOKEN:-}"
    if [ -z "$token" ]; then
        set_dns_error CF_API_UNAUTHORIZED '缺少 Cloudflare API Token' 60
        return $?
    fi

    base="${CFST_CF_API_BASE:-https://api.cloudflare.com/client/v4}"
    # trim trailing slash from base
    case "$base" in
        */) base="${base%/}" ;;
    esac
    case "$path" in
        /*) url="${base}${path}" ;;
        *) url="${base}/${path}" ;;
    esac

    mkdir -p "${CFST_TASK_DIR}" 2>/dev/null || true
    body_file="${CFST_TASK_DIR}/cf_body"
    headers_file="${CFST_TASK_DIR}/cf_headers"
    status_file="${CFST_TASK_DIR}/cf_status"
    CFST_CF_BODY_FILE="$body_file"
    CFST_CF_HEADERS_FILE="$headers_file"

    attempt=0
    max_retries=3
    # delays before retry 1,2,3 → 1,2,4
    while :; do
        rm -f "$body_file" "$headers_file" "$status_file"
        : > "$body_file"
        : > "$headers_file"

        # Do not toggle set -e here; it would leak into the caller shell.
        if [ -n "$body" ]; then
            http_code="$(
                curl --silent --show-error --noproxy '*' \
                    --connect-timeout 15 \
                    --max-time 30 \
                    -X "$method" \
                    -H "Authorization: Bearer ${token}" \
                    -H 'Content-Type: application/json' \
                    --data-binary "$body" \
                    -D "$headers_file" \
                    -o "$body_file" \
                    -w '%{http_code}' \
                    --url "$url" 2>/dev/null
            )" && curl_status=0 || curl_status=$?
        else
            http_code="$(
                curl --silent --show-error --noproxy '*' \
                    --connect-timeout 15 \
                    --max-time 30 \
                    -X "$method" \
                    -H "Authorization: Bearer ${token}" \
                    -H 'Content-Type: application/json' \
                    -D "$headers_file" \
                    -o "$body_file" \
                    -w '%{http_code}' \
                    --url "$url" 2>/dev/null
            )" && curl_status=0 || curl_status=$?
        fi

        case "$http_code" in
            ''|*[!0-9]*)
                if [ "$curl_status" -ne 0 ]; then
                    http_code=0
                else
                    http_code=0
                fi
                ;;
        esac
        CFST_HTTP_STATUS="$http_code"
        printf '%s\n' "$http_code" > "$status_file"

        # Success 2xx with JSON success true, or empty success for non-JSON edge cases
        if [ "$http_code" -ge 200 ] 2>/dev/null && [ "$http_code" -lt 300 ] 2>/dev/null; then
            success="$(_cf_json_get "$body_file" '@.success')"
            if [ "$success" = "true" ] || [ "$success" = "" ]; then
                return 0
            fi
            # 2xx but success:false — treat as API logical error, no retry
            err_code="$(_cf_json_get "$body_file" '@.errors[0].code')"
            err_msg="$(_cf_json_get "$body_file" '@.errors[0].message')"
            [ -n "$err_msg" ] || err_msg='Cloudflare API 返回失败'
            if command -v cfst_log >/dev/null 2>&1; then
                cfst_log error "cf_api ${method} ${path} success=false code=${err_code} msg=${err_msg}"
            fi
            set_dns_error CF_API_TEMPORARY "$err_msg" 63
            return $?
        fi

        retryable=0
        case "$http_code" in
            429|500|502|503|504) retryable=1 ;;
        esac

        if [ "$retryable" -eq 1 ] && [ "$attempt" -lt "$max_retries" ]; then
            retry_after="$(_cf_parse_retry_after "$headers_file")"
            if [ -n "$retry_after" ]; then
                delay="$retry_after"
            else
                # 1, 2, 4
                case "$attempt" in
                    0) delay=1 ;;
                    1) delay=2 ;;
                    *) delay=4 ;;
                esac
            fi
            if command -v cfst_log >/dev/null 2>&1; then
                cfst_log warn "cf_api ${method} ${path} HTTP ${http_code}, retry in ${delay}s"
            fi
            _cf_sleep_delay "$delay"
            attempt=$((attempt + 1))
            continue
        fi

        err_msg="$(_cf_json_get "$body_file" '@.errors[0].message')"
        [ -n "$err_msg" ] || err_msg="HTTP ${http_code}"
        if command -v cfst_log >/dev/null 2>&1; then
            cfst_log error "cf_api ${method} ${path} HTTP ${http_code} msg=${err_msg}"
        fi
        _cf_classify_http "$http_code"
        return $?
    done
}

cf_verify_token() {
    CFST_ERROR_CODE=''
    CFST_ERROR_MESSAGE=''
    cf_api GET /user/tokens/verify || return $?
    success="$(_cf_json_get "${CFST_CF_BODY_FILE}" '@.success')"
    status="$(_cf_json_get "${CFST_CF_BODY_FILE}" '@.result.status')"
    if [ "$success" = "true" ] && [ "$status" = "active" ]; then
        return 0
    fi
    set_dns_error CF_API_UNAUTHORIZED 'Cloudflare Token 无效' 60
    return $?
}

cf_find_zone_id() {
    zone="$1"
    CFST_ERROR_CODE=''
    CFST_ERROR_MESSAGE=''

    # URL-encode is unnecessary for plain zone names (letters/digits/dots/hyphen).
    cf_api GET "/zones?name=${zone}&status=active" || return $?

    count_ids="$(_cf_json_get "${CFST_CF_BODY_FILE}" '@.result[*].id')"
    if [ -z "$count_ids" ]; then
        set_dns_error CF_API_FORBIDDEN "未找到 Zone: ${zone}" 61
        return $?
    fi
    # Multiple lines ⇒ multiple zones
    line_count="$(printf '%s\n' "$count_ids" | awk 'NF { n++ } END { print n+0 }')"
    if [ "$line_count" -ne 1 ]; then
        set_dns_error CF_API_FORBIDDEN "Zone 匹配不唯一: ${zone}" 61
        return $?
    fi
    zone_id="$(_cf_json_get "${CFST_CF_BODY_FILE}" '@.result[0].id')"
    if [ -z "$zone_id" ]; then
        set_dns_error CF_API_FORBIDDEN "未找到 Zone: ${zone}" 61
        return $?
    fi
    printf '%s\n' "$zone_id"
    return 0
}

# Prints one record per line as: id|name|content|type
cf_get_a_records() {
    zone_id="$1"
    fqdn="$2"
    CFST_ERROR_CODE=''
    CFST_ERROR_MESSAGE=''

    cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${fqdn}" || return $?

    ids="$(_cf_json_get "${CFST_CF_BODY_FILE}" '@.result[*].id')"
    if [ -z "$ids" ]; then
        return 0
    fi

    printf '%s\n' "$ids" | while IFS= read -r rid || [ -n "$rid" ]; do
        [ -n "$rid" ] || continue
        # Re-read fields by scanning result array positions is awkward; emit from full result.
        :
    done

    # Emit structured lines via a single pass over result length.
    idx=0
    while :; do
        rid="$(_cf_json_get "${CFST_CF_BODY_FILE}" "@.result[${idx}].id")"
        [ -n "$rid" ] || break
        rname="$(_cf_json_get "${CFST_CF_BODY_FILE}" "@.result[${idx}].name")"
        rcontent="$(_cf_json_get "${CFST_CF_BODY_FILE}" "@.result[${idx}].content")"
        rtype="$(_cf_json_get "${CFST_CF_BODY_FILE}" "@.result[${idx}].type")"
        printf '%s|%s|%s|%s\n' "$rid" "$rname" "$rcontent" "$rtype"
        idx=$((idx + 1))
        # safety cap
        [ "$idx" -lt 50 ] || break
    done
    return 0
}

cf_upsert_a_record() {
    zone_id="$1"
    fqdn="$2"
    ip="$3"
    ttl="${4:-${CFST_TTL:-1}}"
    existing_id="${5:-}"

    CFST_ERROR_CODE=''
    CFST_ERROR_MESSAGE=''

    escaped_name="$(json_escape "$fqdn")"
    escaped_ip="$(json_escape "$ip")"
    body="$(printf '{"type":"A","name":"%s","content":"%s","ttl":%s,"proxied":false}' \
        "$escaped_name" "$escaped_ip" "$ttl")"

    if [ -n "$existing_id" ]; then
        cf_api PUT "/zones/${zone_id}/dns_records/${existing_id}" "$body" || return $?
    else
        cf_api POST "/zones/${zone_id}/dns_records" "$body" || return $?
    fi

    rid="$(_cf_json_get "${CFST_CF_BODY_FILE}" '@.result.id')"
    rname="$(_cf_json_get "${CFST_CF_BODY_FILE}" '@.result.name')"
    rcontent="$(_cf_json_get "${CFST_CF_BODY_FILE}" '@.result.content')"
    if [ -z "$rid" ] || [ -z "$rcontent" ]; then
        set_dns_error DNS_VERIFY_FAILED '创建或更新 DNS 记录后缺少结果' 65
        return $?
    fi
    printf '%s|%s|%s\n' "$rid" "$rname" "$rcontent"
    return 0
}

# GET record, require type A + expected name + expected IP, then DELETE.
# Mismatch ⇒ refuse (return 0, no delete). Hard failures return non-zero.
cf_delete_managed_record() {
    zone_id="$1"
    record_id="$2"
    expected_name="$3"
    expected_ip="$4"

    CFST_ERROR_CODE=''
    CFST_ERROR_MESSAGE=''

    if [ -z "$zone_id" ] || [ -z "$record_id" ] || [ -z "$expected_name" ] || [ -z "$expected_ip" ]; then
        return 0
    fi

    if ! cf_api GET "/zones/${zone_id}/dns_records/${record_id}"; then
        # 404-ish: nothing to delete
        if [ "${CFST_HTTP_STATUS:-}" = "404" ]; then
            CFST_ERROR_CODE=''
            CFST_ERROR_MESSAGE=''
            return 0
        fi
        return $?
    fi

    rname="$(_cf_json_get "${CFST_CF_BODY_FILE}" '@.result.name')"
    rcontent="$(_cf_json_get "${CFST_CF_BODY_FILE}" '@.result.content')"
    rtype="$(_cf_json_get "${CFST_CF_BODY_FILE}" '@.result.type')"

    if [ "$rtype" != "A" ] || [ "$rname" != "$expected_name" ] || [ "$rcontent" != "$expected_ip" ]; then
        if command -v cfst_log >/dev/null 2>&1; then
            cfst_log warn "skip delete managed record ${record_id}: remote no longer matches expected"
        fi
        return 0
    fi

    cf_api DELETE "/zones/${zone_id}/dns_records/${record_id}" || return $?
    return 0
}

_cf_build_managed_json() {
    rid="$1"
    rname="$2"
    rip="$3"
    zone_id="$4"
    escaped_id="$(json_escape "$rid")"
    escaped_name="$(json_escape "$rname")"
    escaped_ip="$(json_escape "$rip")"
    escaped_zone="$(json_escape "$zone_id")"
    printf '{"id":"%s","name":"%s","type":"A","content":"%s","zone_id":"%s"}' \
        "$escaped_id" "$escaped_name" "$escaped_ip" "$escaped_zone"
}

cf_sync_dns() {
    fqdn="$1"
    ip="$2"

    CFST_ERROR_CODE=''
    CFST_ERROR_MESSAGE=''

    zone="${CFST_ZONE:-}"
    if [ -z "$zone" ]; then
        set_dns_error CF_API_FORBIDDEN '缺少 Zone 配置' 61
        return $?
    fi

    prev_managed="${CFST_MANAGED_RECORD:-}"
    state_corrupt="${CFST_STATE_CORRUPT:-0}"

    zone_id="$(cf_find_zone_id "$zone")" || return $?
    [ -n "$zone_id" ] || {
        set_dns_error CF_API_FORBIDDEN '无法解析 Zone ID' 61
        return $?
    }

    records="$(cf_get_a_records "$zone_id" "$fqdn")" || return $?
    rec_count="$(printf '%s\n' "$records" | awk 'NF { n++ } END { print n+0 }')"

    if [ "$rec_count" -gt 1 ]; then
        set_dns_error DNS_MULTIPLE_RECORDS "同名 A 记录多于一条: ${fqdn}" 64
        return $?
    fi

    existing_id=''
    existing_ip=''
    if [ "$rec_count" -eq 1 ]; then
        existing_id="$(printf '%s\n' "$records" | awk -F'|' 'NF { print $1; exit }')"
        existing_ip="$(printf '%s\n' "$records" | awk -F'|' 'NF { print $3; exit }')"
    fi

    if [ "$rec_count" -eq 1 ] && [ "$existing_ip" = "$ip" ]; then
        # Idempotent: no POST/PUT
        rid="$existing_id"
        rname="$fqdn"
        rip="$ip"
    else
        if [ "$rec_count" -eq 1 ]; then
            upsert_out="$(cf_upsert_a_record "$zone_id" "$fqdn" "$ip" "${CFST_TTL:-1}" "$existing_id")" || return $?
        else
            upsert_out="$(cf_upsert_a_record "$zone_id" "$fqdn" "$ip" "${CFST_TTL:-1}")" || return $?
        fi
        rid="$(printf '%s\n' "$upsert_out" | awk -F'|' 'NF { print $1; exit }')"
        rname="$(printf '%s\n' "$upsert_out" | awk -F'|' 'NF { print $2; exit }')"
        rip="$(printf '%s\n' "$upsert_out" | awk -F'|' 'NF { print $3; exit }')"
        [ -n "$rname" ] || rname="$fqdn"
        [ -n "$rip" ] || rip="$ip"
    fi

    # Re-read and verify
    verify="$(cf_get_a_records "$zone_id" "$fqdn")" || return $?
    vcount="$(printf '%s\n' "$verify" | awk 'NF { n++ } END { print n+0 }')"
    if [ "$vcount" -ne 1 ]; then
        set_dns_error DNS_VERIFY_FAILED "校验 DNS 记录数量异常: ${fqdn}" 65
        return $?
    fi
    vid="$(printf '%s\n' "$verify" | awk -F'|' 'NF { print $1; exit }')"
    vcontent="$(printf '%s\n' "$verify" | awk -F'|' 'NF { print $3; exit }')"
    vtype="$(printf '%s\n' "$verify" | awk -F'|' 'NF { print $4; exit }')"
    if [ "$vcontent" != "$ip" ] || [ "$vtype" != "A" ]; then
        set_dns_error DNS_VERIFY_FAILED "校验 DNS 记录内容失败: ${fqdn}" 65
        return $?
    fi
    [ -n "$vid" ] && rid="$vid"
    rip="$vcontent"

    CFST_MANAGED_RECORD="$(_cf_build_managed_json "$rid" "$fqdn" "$rip" "$zone_id")"

    # Cleanup previous managed record only after new metadata is saved.
    if [ "$state_corrupt" = "1" ]; then
        return 0
    fi
    if [ -z "$prev_managed" ] || [ "$prev_managed" = "null" ]; then
        return 0
    fi

    prev_id="$(_cf_json_get_s "$prev_managed" '@.id')"
    prev_name="$(_cf_json_get_s "$prev_managed" '@.name')"
    prev_ip="$(_cf_json_get_s "$prev_managed" '@.content')"
    prev_type="$(_cf_json_get_s "$prev_managed" '@.type')"
    prev_zone="$(_cf_json_get_s "$prev_managed" '@.zone_id')"

    # Require complete prior metadata and type A.
    if [ -z "$prev_id" ] || [ -z "$prev_name" ] || [ -z "$prev_ip" ]; then
        return 0
    fi
    if [ -n "$prev_type" ] && [ "$prev_type" != "A" ]; then
        return 0
    fi
    # Same record already published — nothing to clean.
    if [ "$prev_id" = "$rid" ]; then
        return 0
    fi

    del_zone="$prev_zone"
    [ -n "$del_zone" ] || del_zone="$zone_id"

    if ! cf_delete_managed_record "$del_zone" "$prev_id" "$prev_name" "$prev_ip"; then
        # Publication succeeded; cleanup failed → partial success 66
        if command -v cfst_log >/dev/null 2>&1; then
            cfst_log error "published ${fqdn} but failed to clean previous managed record"
        fi
        set_dns_error DNS_CLEANUP_FAILED '新记录已发布但旧记录清理失败' 66
        return $?
    fi
    return 0
}
