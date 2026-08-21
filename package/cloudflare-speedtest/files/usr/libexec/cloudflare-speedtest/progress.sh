#!/bin/sh
# Turn cfst's progress bar into task status the dashboard can show.
#
# cfst redraws a "done / total [bar]" counter on stdout, using carriage returns
# rather than newlines. The runner captures that stream to a file and polls it
# through here, so a latency sweep over a few thousand addresses reports how far
# it has got instead of looking like a hung task for several minutes.

# progress_snapshot FILE
# Prints "DONE TOTAL" for the most recent counter in the captured stream, or
# nothing when the file holds no counter yet.
progress_snapshot() {
    [ -s "$1" ] || return 1
    tr '\r' '\n' < "$1" | awk '
        {
            for (i = 1; i + 2 <= NF; i++) {
                if ($(i + 1) == "/" && $i ~ /^[0-9]+$/ && $(i + 2) ~ /^[0-9]+$/) {
                    done_count = $i
                    total = $(i + 2)
                }
            }
        }
        END { if (total + 0 > 0) printf "%s %s", done_count + 0, total + 0 }
    '
}

# progress_message LABEL DONE TOTAL ELAPSED_SECONDS
# Prints the status message for a partially complete pass. The estimate is a
# plain linear extrapolation of the observed rate; it is a hint for the user,
# not a promise, and is omitted until at least one item has finished.
progress_message() {
    label="$1"
    done_count="$2"
    total="$3"
    elapsed="$4"
    awk -v label="$label" -v done_count="$done_count" -v total="$total" -v elapsed="$elapsed" '
        BEGIN {
            if (total + 0 <= 0) { printf "%s", label; exit }
            pct = (done_count + 0) * 100 / (total + 0)
            printf "%s %d/%d（%d%%", label, done_count, total, pct
            if (done_count + 0 > 0 && elapsed + 0 > 0 && done_count + 0 < total + 0) {
                remaining = (elapsed + 0) * (total - done_count) / (done_count + 0)
                if (remaining >= 60) {
                    printf "，预计剩余 %d 分 %d 秒", int(remaining / 60), int(remaining % 60)
                } else {
                    printf "，预计剩余 %d 秒", int(remaining + 0.5)
                }
            }
            printf "）"
        }
    '
}
