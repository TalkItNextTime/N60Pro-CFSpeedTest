#!/bin/sh
# shellcheck disable=SC2034

cfst_config_get() {
    uci -q get "cloudflare-speedtest.$1.$2" 2>/dev/null || printf '%s' "$3"
}

set_config_error() {
    CFST_ERROR_CODE="$1"
    CFST_ERROR_MESSAGE="$2"
    return "${3:-21}"
}

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_decimal() {
    case "$1" in
        ''|*[!0-9.]*) return 1 ;;
    esac
    awk -v value="$1" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/) }'
}

number_in_range() {
    awk -v value="$1" -v minimum="$2" -v maximum="$3" \
        'BEGIN { exit !(value >= minimum && value <= maximum) }'
}

validate_uint_range() {
    value="$1"
    minimum="$2"
    maximum="$3"
    error_code="$4"
    error_message="$5"
    if ! is_uint "$value" || ! number_in_range "$value" "$minimum" "$maximum"; then
        set_config_error "$error_code" "$error_message"
        return $?
    fi
}

validate_decimal_range() {
    value="$1"
    minimum="$2"
    maximum="$3"
    error_code="$4"
    error_message="$5"
    if ! is_decimal "$value" || ! number_in_range "$value" "$minimum" "$maximum"; then
        set_config_error "$error_code" "$error_message"
        return $?
    fi
}

is_zone() {
    zone="$1"
    [ ${#zone} -le 253 ] || return 1
    case "$zone" in
        ''|.*|*.|*..*|*[!a-z0-9.-]*) return 1 ;;
    esac
    printf '%s\n' "$zone" | awk -F. '
        NF < 2 { exit 1 }
        {
            for (i = 1; i <= NF; i++) {
                if (length($i) > 63 || $i !~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/) {
                    exit 1
                }
            }
        }
    '
}

load_config() {
    # shellcheck disable=SC2034
    CFST_ERROR_CODE=''
    CFST_ERROR_MESSAGE=''

    CFST_ENABLED="$(cfst_config_get main enabled 1)"
    CFST_INTERVAL_HOURS="$(cfst_config_get main interval_hours 6)"
    CFST_STARTUP_DELAY="$(cfst_config_get main startup_delay 120)"
    CFST_LOG_LEVEL="$(cfst_config_get main log_level info)"

    CFST_API_TOKEN="$(cfst_config_get cloudflare api_token '')"
    CFST_ZONE="$(cfst_config_get cloudflare zone '')"
    CFST_TTL="$(cfst_config_get cloudflare ttl 1)"
    CFST_PROXIED="$(cfst_config_get cloudflare proxied 0)"

    CFST_NAMING_TEMPLATE="$(cfst_config_get naming template 'cf')"
    CFST_AUTO_DETECT="$(cfst_config_get naming auto_detect 1)"
    CFST_CITY_OVERRIDE="$(cfst_config_get naming city_override '')"
    CFST_ISP_OVERRIDE="$(cfst_config_get naming isp_override '')"
    CFST_FALLBACK_CITY="$(cfst_config_get naming fallback_city '')"
    CFST_FALLBACK_ISP="$(cfst_config_get naming fallback_isp '')"

    CFST_THREADS="$(cfst_config_get test threads 50)"
    CFST_ATTEMPTS="$(cfst_config_get test attempts 4)"
    CFST_DOWNLOAD_COUNT="$(cfst_config_get test download_count 10)"
    CFST_DOWNLOAD_SECONDS="$(cfst_config_get test download_seconds 10)"
    CFST_PORT="$(cfst_config_get test port 443)"
    CFST_TEST_URL="$(cfst_config_get test test_url 'https://speed.cloudflare.com/__down?bytes=99000000')"
    CFST_MAX_LATENCY_MS="$(cfst_config_get test max_latency_ms 200)"
    CFST_MAX_LOSS_RATIO="$(cfst_config_get test max_loss_ratio 0.2)"
    CFST_MIN_SPEED_MBPS="$(cfst_config_get test min_speed_mbps 0.01)"
    CFST_TASK_TIMEOUT="$(cfst_config_get test task_timeout_seconds 900)"
    CFST_IP_FILE="$(cfst_config_get test ip_file '/usr/share/cloudflare-speedtest/ip.txt')"
    CFST_IP_SOURCE="$(cfst_config_get test ip_source 'cidr')"
    CFST_CANDIDATE_COUNT="$(cfst_config_get test candidate_count 0)"
    CFST_TEST_ALL="$(cfst_config_get test test_all 0)"
    CFST_DIRECT_MODE="$(cfst_config_get test direct_mode 1)"
    CFST_PUBLISH_SWITCH_MARGIN="$(cfst_config_get test publish_switch_margin 20)"
    CFST_SPEED_WEIGHT="$(cfst_config_get test speed_weight 60)"

    CFST_PREFERRED_PROVIDER="$(cfst_config_get preferred provider 'auto')"
    CFST_PREFERRED_URL_CT="$(cfst_config_get preferred url_ct 'https://cf.090227.xyz/ct?ips=20')"
    CFST_PREFERRED_URL_CU="$(cfst_config_get preferred url_cu 'https://cf.090227.xyz/cu?ips=20')"
    CFST_PREFERRED_URL_CMCC="$(cfst_config_get preferred url_cmcc 'https://cf.090227.xyz/cmcc?ips=20')"
    CFST_PREFERRED_URL_CUSTOM="$(cfst_config_get preferred url_custom '')"
    CFST_PREFERRED_TIMEOUT="$(cfst_config_get preferred timeout 15)"

    CFST_GEO_TIMEOUT="$(cfst_config_get geo request_timeout 8)"
    CFST_GEO_CACHE_TTL_HOURS="$(cfst_config_get geo cache_ttl_hours 72)"
}

validate_base_config() {
    CFST_ERROR_CODE=''
    CFST_ERROR_MESSAGE=''

    case "$CFST_ENABLED" in
        0|1) : ;;
        *) set_config_error CONFIG_ENABLED_INVALID '启用状态必须为 0 或 1'; return $? ;;
    esac
    validate_uint_range "$CFST_INTERVAL_HOURS" 1 24 CONFIG_INTERVAL_INVALID '测速周期必须为 1 到 24 小时' || return $?
    validate_uint_range "$CFST_STARTUP_DELAY" 0 3600 CONFIG_STARTUP_DELAY_INVALID '启动延迟必须为 0 到 3600 秒' || return $?
    case "$CFST_PROXIED" in
        0|1) : ;;
        *) set_config_error CONFIG_PROXY_INVALID '代理模式必须为 0 或 1'; return $? ;;
    esac
    validate_uint_range "$CFST_THREADS" 1 100 CONFIG_THREADS_INVALID '测速线程必须为 1 到 100' || return $?
    validate_uint_range "$CFST_ATTEMPTS" 1 20 CONFIG_ATTEMPTS_INVALID '延迟测试次数必须为 1 到 20' || return $?
    validate_uint_range "$CFST_DOWNLOAD_COUNT" 1 50 CONFIG_DOWNLOAD_COUNT_INVALID '下载候选数必须为 1 到 50' || return $?
    validate_uint_range "$CFST_DOWNLOAD_SECONDS" 1 120 CONFIG_DOWNLOAD_SECONDS_INVALID '单节点下载时间必须为 1 到 120 秒' || return $?
    validate_uint_range "$CFST_PORT" 1 65535 CONFIG_PORT_INVALID '测速端口必须为 1 到 65535' || return $?
    validate_decimal_range "$CFST_MAX_LATENCY_MS" 1 10000 CONFIG_LATENCY_INVALID '最高延迟必须为 1 到 10000 毫秒' || return $?
    validate_decimal_range "$CFST_MAX_LOSS_RATIO" 0 1 CONFIG_LOSS_INVALID '丢包率必须在 0 到 1 之间' || return $?
    validate_decimal_range "$CFST_MIN_SPEED_MBPS" 0 100000 CONFIG_SPEED_INVALID '最低下载速度必须为非负数' || return $?
    validate_uint_range "$CFST_TASK_TIMEOUT" 30 7200 CONFIG_TIMEOUT_INVALID '任务超时必须为 30 到 7200 秒' || return $?
    case "$CFST_TEST_URL" in
        http://*|https://*) : ;;
        *) set_config_error CONFIG_TEST_URL_INVALID '测速地址必须使用 HTTP 或 HTTPS'; return $? ;;
    esac
    case "$CFST_IP_SOURCE" in
        cidr|preferred) : ;;
        *) set_config_error CONFIG_IP_SOURCE_INVALID 'IP 来源必须是 cidr 或 preferred'; return $? ;;
    esac
    validate_uint_range "$CFST_CANDIDATE_COUNT" 0 1000000 CONFIG_CANDIDATE_COUNT_INVALID '随机候选 IP 数量必须为 0 到 1000000' || return $?
    case "$CFST_TEST_ALL" in
        0|1) : ;;
        *) set_config_error CONFIG_TEST_ALL_INVALID '测试全部 IP 必须为 0 或 1'; return $? ;;
    esac
    case "$CFST_DIRECT_MODE" in
        0|1) : ;;
        *) set_config_error CONFIG_DIRECT_MODE_INVALID '直连测速必须为 0 或 1'; return $? ;;
    esac
    validate_uint_range "$CFST_PUBLISH_SWITCH_MARGIN" 0 100 CONFIG_SWITCH_MARGIN_INVALID '切换阈值必须为 0 到 100' || return $?
    validate_uint_range "$CFST_SPEED_WEIGHT" 0 100 CONFIG_SPEED_WEIGHT_INVALID '速度权重必须为 0 到 100' || return $?
    case "$CFST_PREFERRED_PROVIDER" in
        auto|ct|cu|cmcc|custom) : ;;
        *) set_config_error CONFIG_PREFERRED_PROVIDER_INVALID '优选反代提供商无效'; return $? ;;
    esac
    validate_uint_range "$CFST_PREFERRED_TIMEOUT" 1 60 CONFIG_PREFERRED_TIMEOUT_INVALID '优选 URL 超时必须为 1 到 60 秒' || return $?
    case "$CFST_PREFERRED_URL_CT" in http://*|https://*) : ;; *) set_config_error CONFIG_PREFERRED_URL_INVALID '优选 URL 必须使用 HTTP 或 HTTPS'; return $? ;; esac
    case "$CFST_PREFERRED_URL_CU" in http://*|https://*) : ;; *) set_config_error CONFIG_PREFERRED_URL_INVALID '优选 URL 必须使用 HTTP 或 HTTPS'; return $? ;; esac
    case "$CFST_PREFERRED_URL_CMCC" in http://*|https://*) : ;; *) set_config_error CONFIG_PREFERRED_URL_INVALID '优选 URL 必须使用 HTTP 或 HTTPS'; return $? ;; esac
    if [ "$CFST_PREFERRED_PROVIDER" = custom ]; then
        case "$CFST_PREFERRED_URL_CUSTOM" in http://*|https://*) : ;; *) set_config_error CONFIG_PREFERRED_URL_INVALID '自定义优选 URL 必须使用 HTTP 或 HTTPS'; return $? ;; esac
    fi
    if [ -z "$CFST_IP_FILE" ]; then
        set_config_error CONFIG_IP_FILE_MISSING 'IP 段文件路径不能为空'
        return $?
    fi
    return 0
}

validate_publish_config() {
    validate_base_config || return $?
    if [ -z "$CFST_API_TOKEN" ]; then
        set_config_error CONFIG_TOKEN_MISSING 'Cloudflare API Token 未配置' 20
        return $?
    fi
    if [ -z "$CFST_ZONE" ]; then
        set_config_error CONFIG_ZONE_MISSING 'Cloudflare Zone 未配置' 20
        return $?
    fi
    if ! is_zone "$CFST_ZONE"; then
        set_config_error CONFIG_ZONE_INVALID 'Cloudflare Zone 格式无效'
        return $?
    fi
    if ! is_uint "$CFST_TTL"; then
        set_config_error CONFIG_TTL_INVALID 'TTL 必须为自动值 1 或 60 到 86400 秒'
        return $?
    fi
    if [ "$CFST_TTL" != 1 ] && ! number_in_range "$CFST_TTL" 60 86400; then
        set_config_error CONFIG_TTL_INVALID 'TTL 必须为自动值 1 或 60 到 86400 秒'
        return $?
    fi
    return 0
}
