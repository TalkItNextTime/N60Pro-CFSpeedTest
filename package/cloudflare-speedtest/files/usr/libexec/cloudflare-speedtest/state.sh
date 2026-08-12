#!/bin/sh
# shellcheck disable=SC2034

: "${CFST_RUNTIME_DIR:=/tmp/cloudflare-speedtest}"
: "${CFST_STATUS_FILE:=$CFST_RUNTIME_DIR/status.json}"
: "${CFST_STATE_FILE:=/etc/cloudflare-speedtest/state.json}"

cfst_now() {
    if [ -n "${CFST_NOW:-}" ]; then
        printf '%s' "$CFST_NOW"
    else
        date +%s
    fi
}

json_escape() {
    printf '%s' "$1" | awk 'BEGIN { ORS="" }
        {
            if (NR > 1) printf "\\n"
            gsub(/\\/, "\\\\")
            gsub(/"/, "\\\"")
            gsub(/\r/, "\\r")
            gsub(/\t/, "\\t")
            printf "%s", $0
        }'
}

atomic_write() {
    destination="$1"
    directory="${destination%/*}"
    [ "$directory" != "$destination" ] || directory='.'
    mkdir -p "$directory" || return 1
    temporary="$destination.tmp.$$"
    umask 077
    if ! cat > "$temporary"; then
        rm -f "$temporary"
        return 1
    fi
    mv -f "$temporary" "$destination"
}

state_write_status() {
    phase="$1"
    message="$2"
    extra="${3:-}"
    escaped_phase="$(json_escape "$phase")"
    escaped_message="$(json_escape "$message")"
    now="$(cfst_now)"
    if [ -n "$extra" ]; then
        printf '{"phase":"%s","message":"%s","updated_at":%s,%s}\n' \
            "$escaped_phase" "$escaped_message" "$now" "$extra" | atomic_write "$CFST_STATUS_FILE"
    else
        printf '{"phase":"%s","message":"%s","updated_at":%s}\n' \
            "$escaped_phase" "$escaped_message" "$now" | atomic_write "$CFST_STATUS_FILE"
    fi
}

state_init() {
    trigger="${1:-unknown}"
    escaped_trigger="$(json_escape "$trigger")"
    state_write_status preparing 'Preparing task' "\"trigger\":\"$escaped_trigger\""
}

state_set_phase() {
    state_write_status "$1" "$2"
}

state_fail() {
    code="$1"
    message="$2"
    escaped_code="$(json_escape "$code")"
    state_write_status failed "$message" "\"error_code\":\"$escaped_code\""
}

state_success() {
    state_write_status success "$1"
}

state_save_persistent() {
    last_published="${CFST_LAST_PUBLISHED:-null}"
    last_tested="${CFST_LAST_TESTED:-null}"
    geo_cache="${CFST_GEO_CACHE:-null}"
    managed_record="${CFST_MANAGED_RECORD:-null}"
    [ -n "$last_published" ] || last_published=null
    [ -n "$last_tested" ] || last_tested=null
    [ -n "$geo_cache" ] || geo_cache=null
    [ -n "$managed_record" ] || managed_record=null
    printf '{"schema_version":1,"last_published":%s,"last_tested":%s,"geo_cache":%s,"managed_record":%s}\n' \
        "$last_published" "$last_tested" "$geo_cache" "$managed_record" | atomic_write "$CFST_STATE_FILE"
}

state_json_value() {
    jsonfilter -i "$CFST_STATE_FILE" -e "@.$1" 2>/dev/null
}

state_load_persistent() {
    CFST_LAST_PUBLISHED=''
    CFST_LAST_TESTED=''
    CFST_GEO_CACHE=''
    CFST_MANAGED_RECORD=''
    CFST_STATE_CORRUPT=0
    [ -f "$CFST_STATE_FILE" ] || return 0

    schema="$(state_json_value schema_version)" || schema=''
    if [ "$schema" != 1 ]; then
        CFST_STATE_CORRUPT=1
        return 1
    fi

    CFST_LAST_PUBLISHED="$(state_json_value last_published || true)"
    CFST_LAST_TESTED="$(state_json_value last_tested || true)"
    CFST_GEO_CACHE="$(state_json_value geo_cache || true)"
    CFST_MANAGED_RECORD="$(state_json_value managed_record || true)"
    return 0
}
