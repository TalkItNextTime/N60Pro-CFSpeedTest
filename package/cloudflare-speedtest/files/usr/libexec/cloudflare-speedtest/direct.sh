#!/bin/sh
# shellcheck disable=SC2034
# Keep speed test traffic off the local transparent proxy.
#
# A transparent proxy that redirects all outbound TCP answers the TCP handshake
# locally, so cfst measures the proxy's accept time (~1 ms) instead of the real
# RTT and the download reports 0.00 MB/s with no colo. passwall2 keeps a
# `meta mark 0x000000ff ... return` rule for its own loop prevention; marking
# cfst's sockets with the same value is enough to be let out directly.
#
# The rule matches the dedicated uid only, so nothing else on the router
# changes behaviour while a test runs.

: "${CFST_NFT_BIN:=nft}"
: "${CFST_DIRECT_USER:=cfst}"
: "${CFST_DIRECT_TABLE:=cfst_direct}"
: "${CFST_DIRECT_MARK:=0x000000ff}"
# CFST_DIRECT_UID lets the host test suite skip the /etc/passwd lookup; on a
# router it stays unset and the uid is resolved from CFST_DIRECT_USER.

CFST_DIRECT_STATE=''

_direct_nft() {
    command -v "$CFST_NFT_BIN" >/dev/null 2>&1 || return 1
    "$CFST_NFT_BIN" "$@" >/dev/null 2>&1
}

# Prints the user cfst must run as, or nothing when it must stay root.
direct_run_user() {
    [ "${CFST_DIRECT_STATE:-}" = "active" ] || return 0
    printf '%s' "$CFST_DIRECT_USER"
}

direct_enable() {
    [ "${CFST_DIRECT_MODE:-1}" = "1" ] || return 0
    [ "${CFST_DIRECT_STATE:-}" != "active" ] || return 0

    if ! command -v "$CFST_NFT_BIN" >/dev/null 2>&1; then
        cfst_log warn 'direct_mode nft unavailable; speed test stays on the default path'
        return 0
    fi

    uid="${CFST_DIRECT_UID:-$(id -u "$CFST_DIRECT_USER" 2>/dev/null || true)}"
    case "$uid" in
        ''|*[!0-9]*)
            cfst_log warn "direct_mode user missing ($CFST_DIRECT_USER); speed test stays on the default path"
            return 0
            ;;
    esac

    _direct_nft add table inet "$CFST_DIRECT_TABLE" || {
        cfst_log warn 'direct_mode could not create the nftables table'
        return 0
    }
    _direct_nft add chain inet "$CFST_DIRECT_TABLE" mark_out \
        '{ type route hook output priority mangle ; policy accept ; }' || {
        cfst_log warn 'direct_mode could not create the nftables chain'
        _direct_nft delete table inet "$CFST_DIRECT_TABLE"
        return 0
    }
    _direct_nft add rule inet "$CFST_DIRECT_TABLE" mark_out \
        meta skuid "$uid" meta mark set "$CFST_DIRECT_MARK" || {
        cfst_log warn 'direct_mode could not install the marking rule'
        _direct_nft delete table inet "$CFST_DIRECT_TABLE"
        return 0
    }

    CFST_DIRECT_STATE=active
    cfst_log info "direct_mode active user=$CFST_DIRECT_USER uid=$uid mark=$CFST_DIRECT_MARK"
    return 0
}

direct_disable() {
    [ "${CFST_DIRECT_STATE:-}" = "active" ] || return 0
    CFST_DIRECT_STATE=''
    _direct_nft delete table inet "$CFST_DIRECT_TABLE" || true
    return 0
}
