#!/usr/bin/env bash
# Blocking signpost cap, not a length nudge — see ADR-0019 (supersedes ADR-0006).
# THRESHOLD_LINES is the max allowed, so the comparison is `>`, not `>=`.
set -uo pipefail

THRESHOLD_LINES=2

comment_prefix_for() {
  case "$1" in
    *.tf | *.sh) echo '#' ;;
    *) echo '' ;;
  esac
}

status=0

for file in "$@"; do
  [[ -f "$file" ]] || continue
  prefix=$(comment_prefix_for "$file")
  [[ -n "$prefix" ]] || continue

  awk -v prefix="$prefix" -v threshold="$THRESHOLD_LINES" -v file="$file" '
    function report() {
      if (count == 0) return
      # Out of scope: the file-header preamble — the first comment block,
      # nothing above it but a shebang or blanks — no why in it to relocate.
      if (!seen_code && !header_seen) { header_seen = 1; return }
      if (count > threshold) {
        printf "%s:%d: %d-line comment block on one declaration — cap is %d (tripwire + pointer); relocate the why to its ADR/issue home (design-principles.md)\n", file, start, count, threshold
        found = 1
      }
    }
    NR == 1 && $0 ~ /^#!/ { next }
    $0 ~ ("^[ \t]*" prefix "([ \t]|$)") {
      if (count == 0) start = NR
      count++
      next
    }
    { report(); count = 0; if ($0 !~ /^[ \t]*$/) seen_code = 1 }
    END { report(); exit found ? 1 : 0 }
  ' "$file" || status=1
done

exit "$status"
