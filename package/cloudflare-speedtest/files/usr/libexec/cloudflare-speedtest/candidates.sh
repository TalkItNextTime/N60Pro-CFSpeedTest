#!/bin/sh
# Candidate IP selection for CloudflareSpeedTest.
# This file deliberately uses only POSIX shell, awk and standard BusyBox tools.

candidates_clean_source() {
    src="$1"
    dest="$2"
    [ -f "$src" ] || return 1
    awk '
        {
            sub(/\r$/, "")
            sub(/#.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if ($0 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/) print $0
        }
    ' "$src" | sort -u > "$dest"
    [ -s "$dest" ]
}

candidates_count_source() {
    src="$1"
    awk '
        {
            split($0, p, "/")
            if (p[2] == "") {
                if (!seen[p[1]]++) count += 1
            } else if (p[2] >= 0 && p[2] <= 32) {
                key = p[1] "/" p[2]
                if (!seen[key]++) count += (2 ^ (32 - p[2]))
            }
        }
        END { printf "%.0f\n", count + 0 }
    ' "$src"
}

# Pick uniformly from IPv4 ranges without expanding millions of addresses.
candidates_sample_ranges() {
    src="$1"
    count="$2"
    dest="$3"
    awk -v wanted="$count" '
        function ipnum(ip, a) {
            split(ip, a, ".")
            return (((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4])
        }
        function iptext(n) {
            a = int(n / 16777216); n -= a * 16777216
            b = int(n / 65536); n -= b * 65536
            c = int(n / 256); d = n - c * 256
            return a "." b "." c "." d
        }
        {
            split($0, p, "/")
            base = ipnum(p[1])
            prefix = (p[2] == "" ? 32 : p[2] + 0)
            if (prefix < 0 || prefix > 32) next
            size = 2 ^ (32 - prefix)
            start[NR] = int(base / size) * size
            span[NR] = size
            total += size
            ranges = NR
        }
        END {
            if (wanted <= 0 || total <= 0) exit 1
            srand()
            # A bounded retry loop is fine for small samples, but it can
            # under-fill when wanted approaches a small source. Retry more
            # generously and let the caller clamp to the available count.
            emitted = 0
            attempts = 0
            limit = wanted * 1000 + 1000
            while (emitted < wanted && attempts < limit) {
                attempts++
                pick = int(rand() * total)
                cursor = 0
                for (i = 1; i <= ranges; i++) {
                    if (pick < cursor + span[i]) {
                        candidate = iptext(start[i] + (pick - cursor))
                        if (!seen[candidate]++) {
                            print candidate
                            emitted++
                        }
                        break
                    }
                    cursor += span[i]
                }
            }
            if (emitted == 0) exit 1
        }
    ' "$src" > "$dest"
    [ -s "$dest" ]
}

candidates_sample_lines() {
    src="$1"
    count="$2"
    dest="$3"
    awk -v wanted="$count" '
        { if (!seen[$0]++) values[++n] = $0 }
        END {
            if (wanted <= 0 || n <= 0) exit 1
            srand()
            for (i = n; i > 1; i--) {
                j = int(rand() * i) + 1
                tmp = values[i]; values[i] = values[j]; values[j] = tmp
            }
            limit = (wanted < n ? wanted : n)
            for (i = 1; i <= limit; i++) print values[i]
        }
    ' "$src" > "$dest"
    [ -s "$dest" ]
}

# candidates_prepare SOURCE DEST COUNT TEST_ALL
candidates_prepare() {
    source_file="$1"
    output_file="$2"
    requested_count="${3:-0}"
    all_flag="${4:-0}"
    clean_file="${output_file}.clean.$$"
    rm -f "$clean_file" "$output_file"
    if ! candidates_clean_source "$source_file" "$clean_file"; then
        rm -f "$clean_file"
        return 1
    fi

    available_count="$(candidates_count_source "$clean_file" 2>/dev/null || printf '0')"
    case "$available_count" in ''|*[!0-9]*) available_count=0 ;; esac
    CFST_CANDIDATE_AVAILABLE="$available_count"
    export CFST_CANDIDATE_AVAILABLE

    if [ "$all_flag" = "1" ] || [ "$requested_count" = "0" ]; then
        cp "$clean_file" "$output_file"
        copy_status=$?
        rm -f "$clean_file"
        return "$copy_status"
    fi

    if [ "$requested_count" -ge "$available_count" ]; then
        cp "$clean_file" "$output_file"
        sample_status=$?
    elif grep -q '/' "$clean_file" 2>/dev/null; then
        candidates_sample_ranges "$clean_file" "$requested_count" "$output_file"
        sample_status=$?
    else
        candidates_sample_lines "$clean_file" "$requested_count" "$output_file"
        sample_status=$?
    fi
    rm -f "$clean_file"
    return "$sample_status"
}

candidates_next_count() {
    current="$1"
    next=$((current + (current + 1) / 2))
    [ "$next" -gt "$current" ] || next=$((current + 1))
    printf '%s\n' "$next"
}
