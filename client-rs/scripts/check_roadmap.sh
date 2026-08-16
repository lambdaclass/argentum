#!/usr/bin/env bash
# Fail-closed structural gate for the Rust/Bevy client's one task sequence.
set -uo pipefail

client_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
roadmap="$client_dir/ROADMAP.md"
history="$client_dir/CHANGELOG.md"

fail=0
active_ids="$(mktemp)"
closed_ids="$(mktemp)"
all_ids="$(mktemp)"
trap 'rm -f "$active_ids" "$closed_ids" "$all_ids"' EXIT

for required in "$roadmap" "$history"; do
  if [ ! -f "$required" ]; then
    echo "FAIL missing canonical roadmap file: $required"
    fail=$((fail + 1))
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "CLIENT-ROADMAP: FAIL=$fail"
  exit 1
fi

grep -oE '^### Task W-[0-9]{4} — ' "$roadmap" \
  | sed -E 's/^### Task (W-[0-9]{4}) — /\1/' > "$active_ids" || true
grep -oE '^### Completed Task W-[0-9]{4} — ' "$history" \
  | sed -E 's/^### Completed Task (W-[0-9]{4}) — /\1/' > "$closed_ids" || true
cat "$active_ids" "$closed_ids" > "$all_ids"

active_count="$(wc -l < "$active_ids" | tr -d ' ')"
if [ "$active_count" -eq 0 ]; then
  echo "FAIL ROADMAP.md declares no stable task IDs"
  fail=$((fail + 1))
fi

duplicates="$(sort "$all_ids" | uniq -d)"
if [ -n "$duplicates" ]; then
  echo "FAIL task IDs are declared more than once:"
  printf '%s\n' "$duplicates"
  fail=$((fail + 1))
fi

sequence_heading_count="$(grep -c '^## Execution sequence$' "$roadmap" || true)"
if [ "$sequence_heading_count" -ne 1 ]; then
  echo "FAIL expected exactly one Execution sequence heading, found $sequence_heading_count"
  fail=$((fail + 1))
fi

while IFS=: read -r file line ref; do
  if ! grep -qx "$ref" "$all_ids"; then
    echo "FAIL $file:$line: dangling task reference $ref"
    fail=$((fail + 1))
  fi
done < <(grep -nHoE 'W-[0-9]{4}' "$roadmap" "$history" || true)

state_count="$(grep -c '^- \*\*State:\*\* ' "$roadmap" || true)"
phase_count="$(grep -c '^- \*\*Phase:\*\* ' "$roadmap" || true)"
dependency_count="$(grep -c '^- \*\*Depends on:\*\* ' "$roadmap" || true)"
if [ "$state_count" -ne "$active_count" ] \
  || [ "$phase_count" -ne "$active_count" ] \
  || [ "$dependency_count" -ne "$active_count" ]; then
  echo "FAIL each active task needs one State/Phase/Depends on block"
  echo "     tasks=$active_count states=$state_count phases=$phase_count dependencies=$dependency_count"
  fail=$((fail + 1))
fi

if grep -nE '^### Task (W-[0-9]{1,3}|[0-9]+)([^0-9]|$)' "$roadmap"; then
  echo "FAIL malformed or positional task heading"
  fail=$((fail + 1))
fi

if grep -nE '\bTasks? [0-9]+\b' "$roadmap"; then
  echo "FAIL positional task reference; use stable W-NNNN identity"
  fail=$((fail + 1))
fi

parallel_queues="$(grep -nEi '^##+ .*\b(queue|priority list|phase-local tasks)\b' "$roadmap" || true)"
if [ -n "$parallel_queues" ]; then
  echo "FAIL roadmap reintroduced another execution/priority queue:"
  printf '%s\n' "$parallel_queues"
  fail=$((fail + 1))
fi

exit_gate_count="$(grep -cE '^### Phase ([0-9]|10|11) exit gate$' "$roadmap" || true)"
if [ "$exit_gate_count" -ne 12 ]; then
  echo "FAIL expected one exit gate for each of phases 0–11, found $exit_gate_count"
  fail=$((fail + 1))
fi

if [ "$fail" -ne 0 ]; then
  echo "CLIENT-ROADMAP: FAIL=$fail ACTIVE=$active_count"
  exit 1
fi

first="$(head -n 1 "$active_ids")"
echo "CLIENT-ROADMAP: PASS ACTIVE=$active_count FIRST=$first"
