#!/bin/sh
# shellcheck disable=SC2034
# Cron generation, hotplug debounce, and schedule helpers.

: "${CFST_CRONTAB_FILE:=/etc/crontabs/root}"
: "${CFST_CRON_RELOAD_CMD:=/etc/init.d/cron reload}"
: "${CFST_HOTPLUG_DELAY:=300}"
: "${CFST_HOTPLUG_STAMP_FILE:=/tmp/cloudflare-speedtest/hotplug.stamp}"
: "${CFST_WAN_INTERFACE:=wan}"
: "${CFST_BIN:=/usr/bin/cloudflare-speedtest}"
: "${CFST_CRON_MARKER:=# cloudflare-speedtest}"

schedule_now() {
    if [ -n "${CFST_NOW:-}" ]; then
        printf '%s' "$CFST_NOW"
    else
        date +%s
    fi
}

schedule_minute() {
    hostname="$1"
    printf '%s' "$hostname" | cksum | awk '{ print $1 % 60 }'
}

schedule_device_hostname() {
    if [ -n "${CFST_HOSTNAME:-}" ]; then
        printf '%s' "$CFST_HOSTNAME"
        return 0
    fi
    if command -v hostname >/dev/null 2>&1; then
        hostname 2>/dev/null && return 0
    fi
    uname -n 2>/dev/null || printf 'openwrt'
}

validate_interval_hours() {
    case "$1" in
        1|2|3|4|6|8|12|24) return 0 ;;
        *)
            CFST_ERROR_CODE='CONFIG_INTERVAL_INVALID'
            CFST_ERROR_MESSAGE='测速周期必须为 1,2,3,4,6,8,12 或 24 小时'
            return 21
            ;;
    esac
}

schedule_cron_line() {
    interval="$1"
    minute="$2"
    printf '%s */%s * * * %s run --mode test-and-update --trigger cron %s' \
        "$minute" "$interval" "$CFST_BIN" "$CFST_CRON_MARKER"
}

schedule_strip_marked() {
    if [ ! -f "$CFST_CRONTAB_FILE" ]; then
        return 0
    fi
    # Keep every line that does not contain the plugin marker.
    awk -v marker='cloudflare-speedtest' '
        index($0, marker) == 0 { print }
    ' "$CFST_CRONTAB_FILE"
}

schedule_write_crontab() {
    content="$1"
    directory="${CFST_CRONTAB_FILE%/*}"
    if [ "$directory" = "$CFST_CRONTAB_FILE" ]; then
        directory='.'
    fi
    mkdir -p "$directory" || return 1

    temporary="$CFST_CRONTAB_FILE.tmp.$$"
    # Write without a trailing blank-only file when empty content is intended.
    if [ -n "$content" ]; then
        printf '%s\n' "$content" > "$temporary" || {
            rm -f "$temporary"
            return 1
        }
    else
        : > "$temporary" || {
            rm -f "$temporary"
            return 1
        }
    fi
    chmod 0644 "$temporary" || {
        rm -f "$temporary"
        return 1
    }

    changed=1
    if [ -f "$CFST_CRONTAB_FILE" ]; then
        if cmp -s "$temporary" "$CFST_CRONTAB_FILE" 2>/dev/null; then
            changed=0
        fi
    fi

    if [ "$changed" -eq 0 ]; then
        rm -f "$temporary"
        return 0
    fi

    mv -f "$temporary" "$CFST_CRONTAB_FILE" || return 1
    chmod 0644 "$CFST_CRONTAB_FILE" || true

    # shellcheck disable=SC2086
    if [ -n "${CFST_CRON_RELOAD_CMD:-}" ]; then
        eval "$CFST_CRON_RELOAD_CMD" || true
    fi
    return 0
}

schedule_trim_trailing_blanks() {
    awk '
        { lines[NR] = $0 }
        END {
            end = NR
            while (end > 0 && lines[end] == "") end--
            for (i = 1; i <= end; i++) print lines[i]
        }
    '
}

write_cron() {
    CFST_ERROR_CODE=''
    CFST_ERROR_MESSAGE=''

    interval="${CFST_INTERVAL_HOURS:-6}"
    validate_interval_hours "$interval" || return $?

    minute="$(schedule_minute "$(schedule_device_hostname)")"
    line="$(schedule_cron_line "$interval" "$minute")"

    existing="$(schedule_strip_marked | schedule_trim_trailing_blanks)"
    if [ -n "$existing" ]; then
        content="$(printf '%s\n%s' "$existing" "$line")"
    else
        content="$line"
    fi

    schedule_write_crontab "$content"
}

remove_cron() {
    CFST_ERROR_CODE=''
    CFST_ERROR_MESSAGE=''

    if [ ! -f "$CFST_CRONTAB_FILE" ]; then
        return 0
    fi

    existing="$(schedule_strip_marked | schedule_trim_trailing_blanks)"
    schedule_write_crontab "$existing"
}

hotplug_schedule() {
    action="${1:-${ACTION:-}}"
    interface="${2:-${INTERFACE:-}}"

    case "$action" in
        ifup) : ;;
        *) return 0 ;;
    esac

    wan="${CFST_WAN_INTERFACE:-wan}"
    [ "$interface" = "$wan" ] || return 0

    now="$(schedule_now)"
    delay="${CFST_HOTPLUG_DELAY:-300}"
    case "$delay" in
        ''|*[!0-9]*) delay=300 ;;
    esac

    stamp_file="${CFST_HOTPLUG_STAMP_FILE}"
    stamp_dir="${stamp_file%/*}"
    if [ "$stamp_dir" != "$stamp_file" ]; then
        mkdir -p "$stamp_dir" 2>/dev/null || true
    fi

    if [ -f "$stamp_file" ]; then
        last="$(cat "$stamp_file" 2>/dev/null || printf '0')"
        case "$last" in
            ''|*[!0-9]*) last=0 ;;
        esac
        delta=$((now - last))
        if [ "$delta" -ge 0 ] && [ "$delta" -lt "$delay" ]; then
            return 0
        fi
    fi

    printf '%s\n' "$now" > "$stamp_file" || true

    startup_delay="${CFST_STARTUP_DELAY:-120}"
    case "$startup_delay" in
        ''|*[!0-9]*) startup_delay=120 ;;
    esac

    run_cmd="${CFST_HOTPLUG_RUN_CMD:-$CFST_BIN run --mode test-and-update --trigger hotplug}"

    if [ -n "${CFST_HOTPLUG_BG_CMD:-}" ]; then
        "$CFST_HOTPLUG_BG_CMD" "$startup_delay" "$run_cmd"
        return 0
    fi

    (
        ${CFST_SLEEP_CMD:-sleep} "$startup_delay"
        # shellcheck disable=SC2086
        eval "$run_cmd"
    ) >/dev/null 2>&1 &
    return 0
}

apply_schedule() {
    if [ "${CFST_ENABLED:-1}" = "1" ]; then
        write_cron
    else
        remove_cron
    fi
}
