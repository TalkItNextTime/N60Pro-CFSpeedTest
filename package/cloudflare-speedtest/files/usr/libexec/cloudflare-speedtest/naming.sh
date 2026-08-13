#!/bin/sh
# shellcheck disable=SC2034

: "${CFST_CITIES_FILE:=/usr/share/cloudflare-speedtest/cities.tsv}"
: "${CFST_PROVIDERS_FILE:=/usr/share/cloudflare-speedtest/providers.tsv}"

normalize_text() {
    input="$1"
    # Empty or whitespace-only → empty
    trimmed="$(printf '%s' "$input" | awk '{gsub(/^[[:space:]]+|[[:space:]]+$/, "")} 1')"
    [ -n "$trimmed" ] || { printf ''; return 0; }

    # Lowercase ASCII only (Chinese chars pass through unchanged)
    lowered="$(printf '%s' "$trimmed" | tr 'A-Z' 'a-z')"

    # Strip Chinese administrative suffixes 市/省
    case "$lowered" in
        *市) lowered="${lowered%市}" ;;
        *省) lowered="${lowered%省}" ;;
    esac

    printf '%s' "$lowered"
}

# Lookup a normalized needle in a TSV mapping file (code\talias1|alias2|...)
# Matches are case-insensitive for ASCII; Chinese matched as-is after normalize.
_lookup_code() {
    file="$1"
    needle="$2"
    [ -n "$needle" ] || { printf ''; return 0; }
    [ -f "$file" ] || { printf ''; return 0; }

    awk -F '\t' -v needle="$needle" '
        {
            code = $1
            aliases = $2
            if (code == "" ) next
            # Direct code match (case-insensitive)
            if (tolower(code) == needle) {
                print code
                exit 0
            }
            n = split(aliases, parts, "|")
            for (i = 1; i <= n; i++) {
                alias = parts[i]
                # strip surrounding spaces from alias
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", alias)
                if (alias == "") continue
                al = tolower(alias)
                if (al == needle || alias == needle) {
                    print code
                    exit 0
                }
            }
            # Substring match for long org strings such as
            # "CHINANET Guangdong province network". Require alias length
            # >= 4 to avoid short codes like "ct" matching arbitrarily.
            for (i = 1; i <= n; i++) {
                alias = parts[i]
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", alias)
                if (alias == "") continue
                al = tolower(alias)
                if (length(al) >= 4 && index(needle, al) > 0) {
                    print code
                    exit 0
                }
            }
        }
    ' "$file"
}

map_city() {
    raw="$1"
    normalized="$(normalize_text "$raw")"
    [ -n "$normalized" ] || { printf ''; return 0; }
    _lookup_code "$CFST_CITIES_FILE" "$normalized"
}

map_isp() {
    raw="$1"
    normalized="$(normalize_text "$raw")"
    [ -n "$normalized" ] || { printf ''; return 0; }
    _lookup_code "$CFST_PROVIDERS_FILE" "$normalized"
}

choose_location_field() {
    override="$1"
    auto="$2"
    cached="$3"
    fallback="$4"

    if [ -n "$override" ]; then
        printf '%s' "$override"
    elif [ -n "$auto" ]; then
        printf '%s' "$auto"
    elif [ -n "$cached" ]; then
        printf '%s' "$cached"
    elif [ -n "$fallback" ]; then
        printf '%s' "$fallback"
    else
        printf ''
    fi
}

naming_template_is_custom() {
    template="$1"
    case "$template" in
        *'{'*|*'}'*) return 1 ;;
        *) return 0 ;;
    esac
}

render_hostname() {
    template="$1"
    city="$2"
    isp="$3"
    zone="$4"

    CFST_ERROR_CODE=''
    CFST_ERROR_MESSAGE=''

    [ -n "$zone" ] || {
        CFST_ERROR_CODE='NAMING_UNRESOLVED'
        CFST_ERROR_MESSAGE='Zone 字段为空'
        return 40
    }

    # A template without a supported placeholder is a custom relative
    # subdomain.  This is the normal mode: e.g. "cf" becomes
    # "cf.example.com".  Keep the old placeholder syntax for existing UCI
    # configurations and for users who still want location-based names.
    [ -n "$template" ] || {
        CFST_ERROR_CODE='NAMING_UNRESOLVED'
        CFST_ERROR_MESSAGE='模板不能为空'
        return 40
    }

    case "$template" in
        *'{'*'}'*)
            # Replace known placeholders using awk (BusyBox-safe, no bash
            # ${//} needed).  Only placeholders that are actually used need
            # their corresponding location field.
            case "$template" in
                *'{city}'*)
                    [ -n "$city" ] || {
                        CFST_ERROR_CODE='NAMING_UNRESOLVED'
                        CFST_ERROR_MESSAGE='城市字段为空'
                        return 40
                    }
                    ;;
            esac
            case "$template" in
                *'{isp}'*)
                    [ -n "$isp" ] || {
                        CFST_ERROR_CODE='NAMING_UNRESOLVED'
                        CFST_ERROR_MESSAGE='运营商字段为空'
                        return 40
                    }
                    ;;
            esac
            result="$(printf '%s' "$template" | awk -v city="$city" -v isp="$isp" -v zone="$zone" '
                {
                    line = $0
                    gsub(/\{city\}/, city, line)
                    gsub(/\{isp\}/, isp, line)
                    gsub(/\{zone\}/, zone, line)
                    print line
                }
            ')"
            ;;
        *)
            # Custom values are relative to the configured Cloudflare Zone;
            # they must not include the Zone themselves.
            result="${template}.${zone}"
            ;;
    esac

    # Reject any remaining unknown placeholders and validate the final FQDN.
    case "$result" in
        *'{'*'}'*)
            CFST_ERROR_CODE='NAMING_UNRESOLVED'
            CFST_ERROR_MESSAGE='模板包含未知占位符'
            return 40
            ;;
    esac

    if ! validate_hostname "$result"; then
        CFST_ERROR_CODE='NAMING_UNRESOLVED'
        CFST_ERROR_MESSAGE='生成的主机名无效'
        return 40
    fi

    printf '%s' "$result"
}

validate_hostname() {
    fqdn="$1"
    [ -n "$fqdn" ] || return 40

    # Total length limit
    [ "${#fqdn}" -le 253 ] || return 40

    # Only lowercase alphanumeric, hyphen, and dot
    case "$fqdn" in
        *[!a-z0-9.-]*) return 40 ;;
        .*|*.|*..*) return 40 ;;
    esac

    # Validate each label
    printf '%s\n' "$fqdn" | awk -F. '
        BEGIN { status = 0 }
        {
            if (NF < 2) { status = 1; exit }
            for (i = 1; i <= NF; i++) {
                label = $i
                if (length(label) < 1 || length(label) > 63) { status = 1; exit }
                if (label !~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/) { status = 1; exit }
            }
        }
        END { exit status }
    ' || return 40

    return 0
}
