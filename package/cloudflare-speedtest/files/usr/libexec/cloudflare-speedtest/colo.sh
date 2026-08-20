#!/bin/sh
# Cloudflare colo code -> Chinese datacenter name.
#
# The table is a curated subset, not Cloudflare's full colo list. An unknown
# code returns an empty string; callers fall back to showing the raw code.

: "${CFST_COLOS_FILE:=/usr/share/cloudflare-speedtest/colos.tsv}"

colo_chinese_name() {
    code="$1"
    case "$code" in
        ''|'N/A'|*[!A-Za-z]*) return 0 ;;
    esac
    [ -f "$CFST_COLOS_FILE" ] || return 0
    printf '%s\n' "$code" | awk -v table="$CFST_COLOS_FILE" '
        {
            wanted = toupper($0)
            while ((getline line < table) > 0) {
                if (line ~ /^#/ || line == "") continue
                split(line, field, "\t")
                if (toupper(field[1]) == wanted) {
                    printf "%s", field[2]
                    break
                }
            }
            close(table)
        }
    '
}
