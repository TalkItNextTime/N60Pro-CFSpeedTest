#!/bin/sh

: "${CFST_LOG_FILE:=/var/log/cloudflare-speedtest.log}"
: "${CFST_LOG_MAX_BYTES:=262144}"
: "${CFST_LOG_ROTATIONS:=2}"

log_now() {
    if [ -n "${CFST_NOW_TEXT:-}" ]; then
        printf '%s' "$CFST_NOW_TEXT"
    else
        date '+%Y-%m-%d %H:%M:%S'
    fi
}

redact_text() {
    text="$1"
    token="${CFST_API_TOKEN:-}"
    printf '%s' "$text" | awk -v token="$token" '
        {
            line = $0
            gsub(/[Aa]uthorization:[[:space:]]*[Bb]earer[[:space:]]+[^[:space:]]+/, "Authorization: Bearer [REDACTED]", line)
            if (token != "") {
                while ((position = index(line, token)) > 0) {
                    line = substr(line, 1, position - 1) "[REDACTED]" substr(line, position + length(token))
                }
            }
            print line
        }
    '
}

rotate_log_if_needed() {
    incoming_bytes="${1:-0}"
    [ -f "$CFST_LOG_FILE" ] || return 0
    current_bytes="$(wc -c < "$CFST_LOG_FILE" | tr -d ' ')"
    [ $((current_bytes + incoming_bytes)) -le "$CFST_LOG_MAX_BYTES" ] && return 0

    rotation="$CFST_LOG_ROTATIONS"
    while [ "$rotation" -gt 1 ]; do
        previous=$((rotation - 1))
        [ ! -f "$CFST_LOG_FILE.$previous" ] || mv -f "$CFST_LOG_FILE.$previous" "$CFST_LOG_FILE.$rotation"
        rotation="$previous"
    done
    [ ! -f "$CFST_LOG_FILE" ] || mv -f "$CFST_LOG_FILE" "$CFST_LOG_FILE.1"
}

cfst_log() {
    level="$1"
    message="$2"
    timestamp="$(log_now)"
    safe_message="$(redact_text "$message")"
    line="$timestamp [$level] $safe_message"
    directory="${CFST_LOG_FILE%/*}"
    [ "$directory" != "$CFST_LOG_FILE" ] || directory='.'
    mkdir -p "$directory" || return 1
    incoming_bytes="$(printf '%s\n' "$line" | wc -c | tr -d ' ')"
    rotate_log_if_needed "$incoming_bytes"
    printf '%s\n' "$line" >> "$CFST_LOG_FILE"
    logger -t cloudflare-speedtest -- "$line"
}

read_log_bytes() {
    limit="${1:-65536}"
    case "$limit" in
        ''|*[!0-9]*) return 2 ;;
    esac
    [ "$limit" -le 65536 ] || return 2
    [ -f "$CFST_LOG_FILE" ] || return 0
    tail -c "$limit" "$CFST_LOG_FILE"
}

clear_plugin_logs() {
    rm -f "$CFST_LOG_FILE"
    rotation=1
    while [ "$rotation" -le "$CFST_LOG_ROTATIONS" ]; do
        rm -f "$CFST_LOG_FILE.$rotation"
        rotation=$((rotation + 1))
    done
}
