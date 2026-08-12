#!/bin/sh
# shellcheck disable=SC2034

: "${CFST_LOCK_DIR:=/tmp/cloudflare-speedtest/lock}"

lock_now() {
    if [ -n "${CFST_NOW:-}" ]; then
        printf '%s' "$CFST_NOW"
    else
        date +%s
    fi
}

lock_self_pid() {
    printf '%s' "${CFST_SELF_PID:-$$}"
}

read_lock() {
    field="$1"
    case "$field" in
        pid|started_at|trigger) : ;;
        *) return 2 ;;
    esac
    [ -f "$CFST_LOCK_DIR/$field" ] || return 1
    IFS= read -r value < "$CFST_LOCK_DIR/$field" || return 1
    printf '%s' "$value"
}

lock_pid_alive() {
    pid="$1"
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    if [ -n "${CFST_KILL_CMD:-}" ]; then
        "$CFST_KILL_CMD" -0 "$pid" 2>/dev/null
    else
        kill -0 "$pid" 2>/dev/null
    fi
}

write_lock_metadata() {
    trigger="$1"
    self_pid="$(lock_self_pid)"
    printf '%s\n' "$self_pid" > "$CFST_LOCK_DIR/pid" || return 1
    printf '%s\n' "$(lock_now)" > "$CFST_LOCK_DIR/started_at" || return 1
    printf '%s\n' "$trigger" > "$CFST_LOCK_DIR/trigger" || return 1
}

acquire_lock() {
    trigger="$1"
    CFST_ERROR_CODE=''
    CFST_ERROR_MESSAGE=''

    if mkdir "$CFST_LOCK_DIR" 2>/dev/null; then
        if write_lock_metadata "$trigger"; then
            return 0
        fi
        rm -rf "$CFST_LOCK_DIR"
        CFST_ERROR_CODE='TASK_LOCK_WRITE_FAILED'
        CFST_ERROR_MESSAGE='无法写入任务锁信息'
        return 32
    fi

    owner_pid="$(read_lock pid 2>/dev/null || true)"
    if lock_pid_alive "$owner_pid"; then
        CFST_ERROR_CODE='TASK_ALREADY_RUNNING'
        CFST_ERROR_MESSAGE='已有测速任务正在运行'
        return 30
    fi

    case "$owner_pid" in
        ''|*[!0-9]*)
            CFST_ERROR_CODE='TASK_LOCK_INVALID'
            CFST_ERROR_MESSAGE='任务锁损坏，拒绝自动删除'
            return 32
            ;;
    esac

    rm -rf "$CFST_LOCK_DIR" || return 32
    if ! mkdir "$CFST_LOCK_DIR" 2>/dev/null; then
        CFST_ERROR_CODE='TASK_ALREADY_RUNNING'
        CFST_ERROR_MESSAGE='已有测速任务取得任务锁'
        return 30
    fi
    if write_lock_metadata "$trigger"; then
        return 0
    fi
    rm -rf "$CFST_LOCK_DIR"
    CFST_ERROR_CODE='TASK_LOCK_WRITE_FAILED'
    CFST_ERROR_MESSAGE='无法写入任务锁信息'
    return 32
}

release_lock() {
    [ -d "$CFST_LOCK_DIR" ] || return 0
    owner_pid="$(read_lock pid 2>/dev/null || true)"
    self_pid="$(lock_self_pid)"
    if [ "$owner_pid" != "$self_pid" ]; then
        CFST_ERROR_CODE='TASK_LOCK_NOT_OWNER'
        CFST_ERROR_MESSAGE='当前进程不是任务锁所有者'
        return 31
    fi
    rm -rf "$CFST_LOCK_DIR"
}
