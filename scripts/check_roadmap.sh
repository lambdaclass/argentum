#!/usr/bin/env bash
# Fail-closed structural gate for the repository's one task sequence.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
roadmap="$repo_root/ROADMAP.md"
history="$repo_root/CHANGELOG.md"
legacy_client_history="$repo_root/client-rs/CHANGELOG.md"

fail=0
active_ids="$(mktemp)"
closed_ids="$(mktemp)"
all_ids="$(mktemp)"
trap 'rm -f "$active_ids" "$closed_ids" "$all_ids"' EXIT

for required in "$roadmap" "$history" "$legacy_client_history"; do
  if [ ! -f "$required" ]; then
    echo "FAIL missing canonical roadmap file: $required"
    fail=$((fail + 1))
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "ROADMAP: FAIL=$fail"
  exit 1
fi

grep -oE '^### Task W-[0-9]{4} — ' "$roadmap" \
  | sed -E 's/^### Task (W-[0-9]{4}) — /\1/' > "$active_ids" || true
grep -h -oE '^### Completed Task W-[0-9]{4} — ' "$history" "$legacy_client_history" \
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
done < <(grep -nHoE 'W-[0-9]{4}' "$roadmap" "$history" "$legacy_client_history" || true)

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

# A task's metadata must agree with the section that controls its exit gate. Merely
# counting Phase fields allowed a Phase-1 prerequisite to sit under Phase 8, after
# the gate and consumers that needed it, while the roadmap still reported PASS.
phase_mismatches="$(awk '
  /^## Phase / { section=$3; next }
  /^### Task W-[0-9][0-9][0-9][0-9] — / { id=$3; task_section=section; next }
  /^- \*\*Phase:\*\* / {
    declared=$0
    sub(/^- \*\*Phase:\*\* /, "", declared)
    if (task_section == "") {
      printf "%s declares phase %s before any Phase section\n", id, declared
    } else if (declared != task_section) {
      printf "%s is inside Phase %s but declares Phase %s\n", id, task_section, declared
    }
  }
' "$roadmap")"
if [ -n "$phase_mismatches" ]; then
  echo "FAIL task phase metadata disagrees with its containing section:"
  printf '%s\n' "$phase_mismatches"
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

# Nothing may depend on work that comes later in the sequence. The file order *is*
# the order, so a forward dependency is a task that cannot be executed where it
# sits — which is exactly the mistake reordering phases invites.
forward="$(awk -v closed="$closed_ids" '
  /^### Task W-[0-9][0-9][0-9][0-9] — / { id=$3; order[++n]=id; pos[id]=n; current=id; next }
  /^- \*\*Depends on:\*\* / {
    line=$0
    sub(/^- \*\*Depends on:\*\* /, "", line)
    deps[current]=line
    next
  }
  END {
    while ((getline entry < closed) > 0) { closedset[entry]=1 }
    for (i = 1; i <= n; i++) {
      id=order[i]
      rest=deps[id]
      while (match(rest, /W-[0-9][0-9][0-9][0-9]/)) {
        ref=substr(rest, RSTART, RLENGTH)
        rest=substr(rest, RSTART + RLENGTH)
        if (ref in closedset) { continue }
        if (!(ref in pos)) { printf "%s depends on unknown %s\n", id, ref; continue }
        if (pos[ref] > pos[id]) {
          printf "%s depends on %s, which comes later in the sequence\n", id, ref
        }
      }
    }
  }' "$roadmap")"
if [ -n "$forward" ]; then
  echo "FAIL a task depends on work that comes after it:"
  printf '%s\n' "$forward"
  fail=$((fail + 1))
fi

exit_gate_count="$(grep -cE '^### Phase ([0-9]|10|11) exit gate$' "$roadmap" || true)"
if [ "$exit_gate_count" -ne 12 ]; then
  echo "FAIL expected one exit gate for each of phases 0–11, found $exit_gate_count"
  fail=$((fail + 1))
fi

if [ "$fail" -ne 0 ]; then
  echo "ROADMAP: FAIL=$fail ACTIVE=$active_count"
  exit 1
fi

first="$(head -n 1 "$active_ids")"
echo "ROADMAP: PASS ACTIVE=$active_count FIRST=$first"
