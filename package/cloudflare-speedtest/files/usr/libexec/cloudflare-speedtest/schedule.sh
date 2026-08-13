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
: "${CFST_DEFERRED_SCHEDULE_FILE:=/etc/cloudflare-speedtest/schedule-deferred}"

schedule_now() {
    if [ -n "${CFST_NOW:-}" ]; then
        printf '%s' "$CFST_NOW"
    else
        date +%s
    fi
}

schedule_minute() {
    hostname="$1"
    # Prefer cksum when available (host tests / full BusyBox); fall back for
    # minimal OpenWrt images that omit cksum but ship md5sum or od.
    if command -v cksum >/dev/null 2>&1; then
        printf '%s' "$hostname" | cksum | awk '{ print $1 % 60 }'
        return 0
    fi
    if command -v md5sum >/dev/null 2>&1; then
        printf '%s' "$hostname" | md5sum | awk '{
            h = substr($1, 1, 4)
            n = 0
            for (i = 1; i <= length(h); i++) {
                c = substr(h, i, 1)
                if (c >= "0" && c <= "9") d = c + 0
                else if (c >= "a" && c <= "f") d = 10 + index("abcdef", c) - 1
                else if (c >= "A" && c <= "F") d = 10 + index("ABCDEF", c) - 1
                else d = 0
                n = n * 16 + d
            }
            print n % 60
        }'
        return 0
    fi
    if command -v od >/dev/null 2>&1; then
        printf '%s' "$hostname" | od -An -tu1 | awk '{
            for (i = 1; i <= NF; i++) s += $i
            print s % 60
        }'
        return 0
    fi
    # Last resort: fixed offset so cron line is still valid.
    printf '17\n'
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

schedule_next_run_epoch() {
    interval="${1:-6}"
    minute="${2:-17}"
    hours="${3:-}"
    case "$interval:$minute" in *[!0-9:]*|*:|:*) return 1 ;; esac
    now="$(schedule_now)"
    case "$now" in ''|*[!0-9]*) return 1 ;; esac
    hour="$(date +%H)"
    current_minute="$(date +%M)"
    second="$(date +%S)"
    hour="$(printf '%s\n' "$hour" | awk '{print $1 + 0}')"
    current_minute="$(printf '%s\n' "$current_minute" | awk '{print $1 + 0}')"
    second="$(printf '%s\n' "$second" | awk '{print $1 + 0}')"
    day_start=$((now - hour * 3600 - current_minute * 60 - second))

    # The normal schedule is */N. A manual successful DNS publish uses an
    # explicit list (e.g. 2,8,14,20) re-anchored from the publish time.
    if [ -n "$hours" ]; then
        case "$hours" in *[!0-9,]*|,*|*,,*) return 1 ;; esac
        day_offset=0
        while [ "$day_offset" -le 1 ]; do
            for h in $(printf '%s' "$hours" | tr ',' ' '); do
                candidate=$((day_start + day_offset * 86400 + h * 3600 + minute * 60))
                if [ "$candidate" -gt "$now" ]; then
                    printf '%s\n' "$candidate"
                    return 0
                fi
            done
            day_offset=$((day_offset + 1))
        done
        return 1
    fi

    h=0
    while [ "$h" -lt 24 ]; do
        if [ $((h % interval)) -eq 0 ] && { [ "$h" -gt "$hour" ] || { [ "$h" -eq "$hour" ] && [ "$minute" -gt "$current_minute" ]; }; }; then
            printf '%s\n' $((day_start + h * 3600 + minute * 60))
            return 0
        fi
        h=$((h + 1))
    done
    printf '%s\n' $((day_start + 86400 + minute * 60))
}

schedule_cron_line() {
    interval="$1"
    minute="$2"
    hours="${3:-*/$interval}"
    printf '%s %s * * * %s run --mode test-and-update --trigger cron %s' \
        "$minute" "$hours" "$CFST_BIN" "$CFST_CRON_MARKER"
}

schedule_date_field() {
    epoch="$1"
    format="$2"
    # Callers pass a strftime field such as M or H. Prefix %, otherwise
    # BusyBox/GNU date prints the literal field letter (e.g. "M") and a
    # deferred cron schedule incorrectly becomes minute/hour zero.
    date -d "@$epoch" "+%$format" 2>/dev/null || date -r "$epoch" "+%$format" 2>/dev/null
}

schedule_hour_list() {
    interval="$1"
    anchor_hour="$2"
    case "$interval:$anchor_hour" in *[!0-9:]*|*:|:*) return 1 ;; esac
    [ "$anchor_hour" -ge 0 ] 2>/dev/null && [ "$anchor_hour" -le 23 ] 2>/dev/null || return 1
    list=''
    hour=0
    while [ "$hour" -lt 24 ]; do
        if [ $(((hour - anchor_hour + 24) % interval)) -eq 0 ]; then
            if [ -n "$list" ]; then list="$list,$hour"; else list="$hour"; fi
        fi
        hour=$((hour + 1))
    done
    printf '%s\n' "$list"
}

# A successful manual DNS publish re-anchors the repeating cron schedule.
# Keep that anchor outside /tmp so an init/LuCI reload cannot immediately
# replace it with the generic */N line.
schedule_deferred_line() {
    requested_interval="$1"
    [ -f "$CFST_DEFERRED_SCHEDULE_FILE" ] || return 1
    IFS=' ' read -r due stored_interval < "$CFST_DEFERRED_SCHEDULE_FILE" || return 1
    case "$due:$stored_interval:$requested_interval" in *[!0-9:]*|*:|:*) return 1 ;; esac
    [ "$stored_interval" = "$requested_interval" ] || return 1
    minute="$(schedule_date_field "$due" M)" || return 1
    anchor_hour="$(schedule_date_field "$due" H)" || return 1
    minute="$(printf '%s\n' "$minute" | awk '{ print $1 + 0 }')"
    anchor_hour="$(printf '%s\n' "$anchor_hour" | awk '{ print $1 + 0 }')"
    hours="$(schedule_hour_list "$requested_interval" "$anchor_hour")" || return 1
    schedule_cron_line "$requested_interval" "$minute" "$hours"
}

schedule_store_deferred() {
    due="$1"
    interval="$2"
    case "$due:$interval" in *[!0-9:]*|*:|:*) return 1 ;; esac
    directory="${CFST_DEFERRED_SCHEDULE_FILE%/*}"
    [ "$directory" = "$CFST_DEFERRED_SCHEDULE_FILE" ] && directory='.'
    mkdir -p "$directory" || return 1
    temporary="${CFST_DEFERRED_SCHEDULE_FILE}.tmp.$$"
    printf '%s %s\n' "$due" "$interval" > "$temporary" || return 1
    chmod 0600 "$temporary" 2>/dev/null || true
    mv -f "$temporary" "$CFST_DEFERRED_SCHEDULE_FILE" || return 1
}

schedule_clear_deferred() {
    rm -f "$CFST_DEFERRED_SCHEDULE_FILE"
}

# Re-anchor the recurring cron hours after a successful manual DNS publication.
# All accepted intervals divide 24, so a comma-separated hour list preserves
# exactly one interval between executions across midnight.
schedule_defer_after_manual_success() {
    CFST_SCHEDULE_NEXT_RUN_AT=''
    [ "${CFST_ENABLED:-1}" = "1" ] || return 0
    interval="${CFST_INTERVAL_HOURS:-6}"
    validate_interval_hours "$interval" || return $?
    now="$(schedule_now)"
    case "$now" in ''|*[!0-9]*) return 1 ;; esac
    # Cron has minute resolution: never schedule before a full interval elapsed.
    due=$((now + interval * 3600 + 59))
    due=$(((due / 60) * 60))
    minute="$(schedule_date_field "$due" M)" || return 1
    anchor_hour="$(schedule_date_field "$due" H)" || return 1
    minute="$(printf '%s\n' "$minute" | awk '{ print $1 + 0 }')"
    anchor_hour="$(printf '%s\n' "$anchor_hour" | awk '{ print $1 + 0 }')"
    hours="$(schedule_hour_list "$interval" "$anchor_hour")" || return 1
    line="$(schedule_cron_line "$interval" "$minute" "$hours")"
    existing="$(schedule_strip_marked | schedule_trim_trailing_blanks)"
    if [ -n "$existing" ]; then content="$(printf '%s\n%s' "$existing" "$line")"; else content="$line"; fi
    schedule_write_crontab "$content" || return 1
    # Persist after the cron line is in place so later apply-schedule keeps it.
    schedule_store_deferred "$due" "$interval" || return 1
    CFST_SCHEDULE_NEXT_RUN_AT="$due"
    export CFST_SCHEDULE_NEXT_RUN_AT
    return 0
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
    # Retain a manual-success anchor for the same interval across service
    # reloads; without this, procd overwrites the deferred cron line with */N.
    line="$(schedule_deferred_line "$interval" 2>/dev/null || true)"
    [ -n "$line" ] || line="$(schedule_cron_line "$interval" "$minute")"

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
    schedule_write_crontab "$existing" || return 1
    schedule_clear_deferred
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
