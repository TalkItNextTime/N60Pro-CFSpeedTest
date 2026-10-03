#!/bin/sh
# shellcheck disable=SC2034
# Keep the plugin's own traffic off the local transparent proxy.
#
# A transparent proxy that redirects all outbound TCP answers the TCP handshake
# locally, so cfst measures the proxy's accept time (~1 ms) instead of the real
# RTT, and API calls fail or leave through a proxy node. Different proxies need
# different escape hatches, so the channel stacks three independent ones:
#
#   1. identity DNAT in a nat/output chain that runs before every proxy's
#      redirect chain. Once a connection has a NAT binding, later nat chains
#      on the same hook are skipped, so no redirect-type proxy can grab it.
#   2. mark 0x000000ff, the value passwall2 returns early on for loop prevention.
#   3. cfst runs with group nogroup (gid 65534), which OpenClash returns early
#      on for its own daemons.
#
# Matching is limited to the dedicated cfst uid (speed test) and to the real
# addresses of the hosts the plugin itself calls (API, GeoIP, preferred list),
# and only in the output hook: forwarded LAN traffic is never touched.

: "${CFST_NFT_BIN:=nft}"
: "${CFST_DIRECT_USER:=cfst}"
: "${CFST_DIRECT_GROUP:=nogroup}"
: "${CFST_DIRECT_TABLE:=cfst_direct}"
: "${CFST_DIRECT_MARK:=0x000000ff}"
: "${CFST_GROUP_FILE:=/etc/group}"
# Public resolvers used to learn a host's real address; fake-ip DNS on the
# router would hand out 198.18.0.0/15 placeholders. An empty value disables
# resolution (host tests), and callers then fall back to plain curl.
: "${CFST_DIRECT_DNS=223.5.5.5 119.29.29.29}"
# CFST_DIRECT_UID lets the host test suite skip the /etc/passwd lookup; on a
# router it stays unset and the uid is resolved from CFST_DIRECT_USER.

CFST_DIRECT_STATE=''

_direct_nft() {
    command -v "$CFST_NFT_BIN" >/dev/null 2>&1 || return 1
    "$CFST_NFT_BIN" "$@" >/dev/null 2>&1
}

# Prints the user[:group] cfst must run as, or nothing when it must stay root.
direct_run_user() {
    [ "${CFST_DIRECT_STATE:-}" = "active" ] || return 0
    if [ -n "$CFST_DIRECT_GROUP" ] && grep -q "^${CFST_DIRECT_GROUP}:" "$CFST_GROUP_FILE" 2>/dev/null; then
        printf '%s:%s' "$CFST_DIRECT_USER" "$CFST_DIRECT_GROUP"
    else
        printf '%s' "$CFST_DIRECT_USER"
    fi
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

    # A previous run killed with SIGKILL may have left the table behind.
    _direct_nft delete table inet "$CFST_DIRECT_TABLE" || true
    _direct_nft add table inet "$CFST_DIRECT_TABLE" || {
        cfst_log warn 'direct_mode could not create the nftables table'
        return 0
    }
    if ! _direct_nft add set inet "$CFST_DIRECT_TABLE" dst4 '{ type ipv4_addr ; }' ||
       ! _direct_nft add chain inet "$CFST_DIRECT_TABLE" mark_out \
            '{ type route hook output priority mangle ; policy accept ; }' ||
       ! _direct_nft add rule inet "$CFST_DIRECT_TABLE" mark_out \
            meta skuid "$uid" meta mark set "$CFST_DIRECT_MARK" ||
       ! _direct_nft add rule inet "$CFST_DIRECT_TABLE" mark_out \
            ip daddr @dst4 meta mark set "$CFST_DIRECT_MARK"; then
        cfst_log warn 'direct_mode could not install the marking rules'
        _direct_nft delete table inet "$CFST_DIRECT_TABLE"
        return 0
    fi
    # nat chains must sit above -200; -190 still runs before dstnat (-100) and
    # the proxies' output chains (around -1).
    if _direct_nft add chain inet "$CFST_DIRECT_TABLE" nat_out \
            '{ type nat hook output priority -190 ; policy accept ; }' &&
       _direct_nft add rule inet "$CFST_DIRECT_TABLE" nat_out \
            meta skuid "$uid" meta nfproto ipv4 meta l4proto tcp dnat ip to ip daddr &&
       _direct_nft add rule inet "$CFST_DIRECT_TABLE" nat_out \
            meta nfproto ipv4 ip daddr @dst4 meta l4proto tcp dnat ip to ip daddr; then
        nat=on
    else
        # Marking alone still covers passwall2, and nogroup covers OpenClash.
        nat=off
        cfst_log warn 'direct_mode could not install the NAT rules; relying on mark and group only'
    fi

    CFST_DIRECT_STATE=active
    cfst_log info "direct_mode active user=$(direct_run_user) uid=$uid mark=$CFST_DIRECT_MARK nat=$nat"
    return 0
}

direct_disable() {
    [ "${CFST_DIRECT_STATE:-}" = "active" ] || return 0
    CFST_DIRECT_STATE=''
    _direct_nft delete table inet "$CFST_DIRECT_TABLE" || true
    return 0
}

# Print the first real IPv4 address of HOST, or nothing.
_direct_resolve() {
    _dr_host="$1"
    for _dr_srv in $CFST_DIRECT_DNS; do
        _dr_ip="$(nslookup "$_dr_host" "$_dr_srv" 2>/dev/null | awk '
            /^Name:/ { named = 1 }
            named && /^Address/ && $NF ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $NF; exit }
        ')"
        case "$_dr_ip" in
            ''|198.18.*|198.19.*) continue ;;
        esac
        printf '%s' "$_dr_ip"
        return 0
    done
    return 1
}

# Drop-in for curl that sends the request through the direct channel. Callers
# must pass the target with --url. Without an active channel, or when the host
# cannot be resolved, it degrades to plain curl.
direct_curl() {
    [ "${CFST_DIRECT_STATE:-}" = "active" ] || { curl "$@"; return; }
    _dc_url=''
    _dc_prev=''
    for _dc_arg in "$@"; do
        [ "$_dc_prev" = "--url" ] && _dc_url="$_dc_arg"
        _dc_prev="$_dc_arg"
    done
    _dc_hostport="${_dc_url#*://}"
    _dc_hostport="${_dc_hostport%%/*}"
    _dc_hostport="${_dc_hostport%%\?*}"
    _dc_host="${_dc_hostport%%:*}"
    _dc_port="${_dc_hostport#*:}"
    if [ "$_dc_port" = "$_dc_hostport" ]; then
        case "$_dc_url" in https://*) _dc_port=443 ;; *) _dc_port=80 ;; esac
    fi
    case "$_dc_host" in
        ''|localhost|127.*) curl "$@"; return ;;
    esac
    if printf '%s' "$_dc_host" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        _direct_nft add element inet "$CFST_DIRECT_TABLE" dst4 "{ $_dc_host }" || true
        curl "$@"
        return
    fi
    _dc_ip="$(_direct_resolve "$_dc_host" || true)"
    if [ -z "$_dc_ip" ]; then
        cfst_log warn "direct_mode could not resolve $_dc_host; using the default path" 2>/dev/null || true
        curl "$@"
        return
    fi
    _direct_nft add element inet "$CFST_DIRECT_TABLE" dst4 "{ $_dc_ip }" || true
    curl --resolve "$_dc_host:$_dc_port:$_dc_ip" "$@"
}
