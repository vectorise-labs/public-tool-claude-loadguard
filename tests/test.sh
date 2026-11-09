#!/bin/bash
# loadguard test suite. Uses a throwaway LOADGUARD_HOME and fake metrics, so it
# never touches your real state or processes. Run: tests/test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LG="$ROOT/bin/loadguard"
export LOADGUARD_NO_MONITOR=1 LOADGUARD_HOME; LOADGUARD_HOME="$(mktemp -d)"
trap 'rm -rf "$LOADGUARD_HOME"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ✓ $1"; }
bad()  { fail=$((fail+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/      /'; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

# Fake a monitor sample (fresh, so hooks trust it).
fake() {  # fake <cpu> <mem_free> <pressure> [swapout_rate] [load_ratio]
  mkdir -p "$LOADGUARD_HOME/state"
  cat > "$LOADGUARD_HOME/state/metrics" <<EOF
ts=$(date +%s)
source=monitor
cpu=$1
load_ratio=${5:-1.0}
mem_free=$2
pressure=$3
swap_used_mb=100
swapout_rate=${4:-0}
thermal=100
level=ok
reasons=""
EOF
}
hook() {  # hook <Event> <json>
  printf '%s' "$2" | "$LG" hook "$1"
}
valid_json() { printf '%s' "$1" | jq -e . >/dev/null 2>&1; }

echo "capacity scan"
out=$("$LG" scan)
check "scan writes cores/memory/slots" 'echo "$out" | grep -q "^ncpu=" && echo "$out" | grep -q "^heavy_slots="'

echo "classification"
fake 30 60 1;  check "low load -> idle"            '"$LG" status | grep -q "^loadguard: idle"'
fake 60 50 1;  check "moderate -> ok"              '"$LG" status | grep -q "^loadguard: ok"'
fake 92 50 1;  check "CPU 92% -> throttled"        '"$LG" status | grep -q "^loadguard: throttled"'
fake 50 50 2;  check "pressure warn -> throttled"  '"$LG" status | grep -q "^loadguard: throttled"'
fake 50 15 1;  check "15% available -> throttled"  '"$LG" status | grep -q "^loadguard: throttled"'
fake 50 50 1 500; check "swapping -> throttled"    '"$LG" status | grep -q "^loadguard: throttled"'
fake 85 50 1 0 4.0; check "CPU 85% + run queue 4x -> throttled" '"$LG" status | grep -q "^loadguard: throttled"'
fake 99 50 1;  check "CPU 99% -> severe"           '"$LG" status | grep -q "^loadguard: severe"'
fake 50 50 4;  check "pressure critical -> severe" '"$LG" status | grep -q "^loadguard: severe"'
fake 50 50 1;  check "status --json is valid"      'valid_json "$("$LG" status --json)"'
rm -f "$LOADGUARD_HOME/state/episode"

echo "hooks: healthy machine stays silent / encouraging"
fake 30 60 1
out=$(hook SessionStart '{"session_id":"s1","source":"startup"}')
check "SessionStart emits valid capacity context" 'valid_json "$out" && echo "$out" | grep -q "spare capacity"' "$out"
envf="$LOADGUARD_HOME/envfile"; : > "$envf"
CLAUDE_ENV_FILE="$envf" hook SessionStart '{"session_id":"s1","source":"startup"}' >/dev/null
CLAUDE_ENV_FILE="$envf" hook SessionStart '{"session_id":"s1","source":"resume"}' >/dev/null
check "SessionStart puts the CLI on PATH via CLAUDE_ENV_FILE (once)" '[ "$(grep -c "$ROOT/bin" "$envf")" = 1 ]' "$(cat "$envf")"
out=$(PATH=/usr/bin:/bin hook SessionStart '{"session_id":"s1","source":"startup"}')
check "without CLAUDE_ENV_FILE, brief gives the absolute CLI path" 'echo "$out" | grep -q "$ROOT/bin/loadguard"' "$out"
out=$(hook UserPromptSubmit '{"session_id":"s1","prompt":"hi"}')
check "UserPromptSubmit silent when healthy" '[ -z "$out" ]' "$out"
out=$(hook PostToolUse '{"session_id":"s1","tool_name":"Read","tool_use_id":"t1"}')
check "PostToolUse silent when healthy" '[ -z "$out" ]' "$out"
out=$(hook PreToolUse '{"session_id":"s1","tool_name":"Bash","tool_use_id":"t2","tool_input":{"command":"npm test"}}')
check "heavy Bash allowed instantly when healthy" '[ -z "$out" ]' "$out"
check "heavy Bash took a slot" '[ -f "$LOADGUARD_HOME/slots/t2" ]'
hook PostToolUse '{"session_id":"s1","tool_name":"Bash","tool_use_id":"t2"}' >/dev/null
check "PostToolUse released the slot" '[ ! -f "$LOADGUARD_HOME/slots/t2" ]'
out=$(hook PreToolUse '{"session_id":"s1","tool_name":"Agent","tool_use_id":"t3","tool_input":{}}')
check "Agent spawn gets planning budget" 'valid_json "$out" && echo "$out" | grep -q "Parallelise"' "$out"
out=$(hook PreToolUse '{"session_id":"s1","tool_name":"Bash","tool_use_id":"t4","tool_input":{"command":"loadguard status"}}')
check "own read-only command auto-approved" 'echo "$out" | grep -q "\"allow\""' "$out"
out=$(hook PreToolUse '{"session_id":"s1","tool_name":"Bash","tool_use_id":"t5","tool_input":{"command":"loadguard status; rm -rf x"}}')
check "chained command NOT auto-approved" '! echo "$out" | grep -q "\"allow\""' "$out"
out=$(hook PreToolUse '{"session_id":"s1","tool_name":"Bash","tool_use_id":"t6","tool_input":{"command":"ls -la"}}')
check "light Bash untouched" '[ -z "$out" ]' "$out"

echo "hooks: throttled machine"
fake 95 50 1
out=$(hook PostToolUse '{"session_id":"s1","tool_name":"Read","tool_use_id":"t7"}')
check "mid-run notice on first tool after throttle" 'valid_json "$out" && echo "$out" | grep -q "throttling" && echo "$out" | grep -q "loadguard tree"' "$out"
out=$(hook PostToolUse '{"session_id":"s1","tool_name":"Read","tool_use_id":"t8"}')
check "notice not repeated in same episode" '[ -z "$out" ]' "$out"
out=$(hook PostToolUse '{"session_id":"s1","agent_id":"a1","tool_name":"Read","tool_use_id":"t9"}')
check "each subagent is told once too" 'echo "$out" | grep -q "throttling"' "$out"
check "kill prompt only offered once machine-wide" '! echo "$out" | grep -q "Ask the user ONCE"' "$out"
out=$(hook UserPromptSubmit '{"session_id":"s2","prompt":"go"}')
check "UserPromptSubmit injects playbook when throttled" 'valid_json "$out" && echo "$out" | grep -q "Queue heavy work"' "$out"
out=$(hook SubagentStart '{"session_id":"s1","agent_id":"a2"}')
check "SubagentStart warns when throttled" 'echo "$out" | grep -q "queue heavy work"' "$out"

echo "queueing"
start=$(date +%s)
out=$(LOADGUARD_QUEUE_WAIT=4 hook PreToolUse '{"session_id":"s1","tool_name":"Bash","tool_use_id":"q1","tool_input":{"command":"docker compose up -d"}}')
el=$(( $(date +%s) - start ))
check "heavy Bash waits in queue then denies with replan reason" 'echo "$out" | grep -q "\"deny\"" && [ $el -ge 3 ]' "$out (elapsed $el)"
out=$(LOADGUARD_QUEUE_WAIT=3 hook PreToolUse '{"session_id":"s1","tool_name":"Bash","tool_use_id":"q2","tool_input":{"command":"docker compose up -d"}}')
check "second attempt by same agent is let through (never deadlocks)" '! echo "$out" | grep -q "\"deny\""' "$out"
hook PostToolUse '{"session_id":"s1","tool_name":"Bash","tool_use_id":"q2"}' >/dev/null
# queue releases when pressure drops mid-wait
( sleep 3; fake 40 60 1 ) &
start=$(date +%s)
out=$(LOADGUARD_QUEUE_WAIT=20 hook PreToolUse '{"session_id":"s3","tool_name":"Bash","tool_use_id":"q3","tool_input":{"command":"cargo build --release"}}')
el=$(( $(date +%s) - start )); wait
check "queued command proceeds as soon as pressure clears" '! echo "$out" | grep -q "\"deny\"" && [ $el -ge 2 ] && [ $el -lt 15 ]' "$out (elapsed $el)"
hook PostToolUse '{"session_id":"s3","tool_name":"Bash","tool_use_id":"q3"}' >/dev/null

echo "slots cap concurrency when busy"
fake 75 50 1   # 'ok' (busy-ish), not idle
. "$LOADGUARD_HOME/capacity"
for i in $(seq 1 "$heavy_slots"); do echo "$$ $(date +%s)" > "$LOADGUARD_HOME/slots/fill$i"; done
start=$(date +%s)
out=$(LOADGUARD_QUEUE_WAIT=3 hook PreToolUse '{"session_id":"s4","tool_name":"Bash","tool_use_id":"q4","tool_input":{"command":"pytest -x"}}')
el=$(( $(date +%s) - start ))
check "full slots + busy -> waits" '[ $el -ge 2 ]' "elapsed $el"
fake 30 60 1
out=$(LOADGUARD_QUEUE_WAIT=3 hook PreToolUse '{"session_id":"s5","tool_name":"Bash","tool_use_id":"q5","tool_input":{"command":"pytest -x"}}')
check "full slots but idle machine -> runs anyway (use the capacity)" '[ -z "$out" ]' "$out"
rm -f "$LOADGUARD_HOME"/slots/*
echo "1999999 $(date +%s)" > "$LOADGUARD_HOME/slots/stale"
check "slots owned by dead sessions are reclaimed" '"$LG" status --json | grep -q "\"slots_in_use\":0"'

echo "episode clears -> resume notice"
fake 95 50 1; hook PostToolUse '{"session_id":"s9","tool_name":"Read","tool_use_id":"e1"}' >/dev/null
printf '%s\n%s\n' "$(sed -n 1p "$LOADGUARD_HOME/state/episode")" "$(( $(date +%s) - 120 ))" > "$LOADGUARD_HOME/state/episode"
fake 30 60 1
out=$(hook PostToolUse '{"session_id":"s9","tool_name":"Read","tool_use_id":"e2"}')
check "agent told to return to full speed after pressure clears" 'echo "$out" | grep -q "full speed"' "$out"

echo "locks"
out=$("$LG" lock browser "ws://127.0.0.1:9222")
check "lock claims resource" 'echo "$out" | grep -q "^OK"' "$out"
check "locks lists it with note" '"$LG" locks | grep -q "9222"'
"$LG" unlock browser >/dev/null
check "unlock releases" '"$LG" locks | grep -q "no shared"'

echo "run wrapper cleans up its process group"
fake 30 60 1
"$LG" run -- bash -c 'sleep 300 & echo $! > '"$LOADGUARD_HOME"'/child; exit 0'
sleep 0.5
check "background child of wrapped command was killed" '! kill -0 "$(cat "$LOADGUARD_HOME/child")" 2>/dev/null'
"$LG" run -- bash -c 'exit 7'; rc=$?
check "run preserves exit code" '[ $rc -eq 7 ]'

echo "misc"
check "procs runs" '"$LG" procs --no-docker | head -1 | grep -q PID'
check "tree runs" '"$LG" tree >/dev/null'
check "LOADGUARD_DISABLE=1 makes hooks inert" '[ -z "$(LOADGUARD_DISABLE=1 hook SessionStart "{}")" ]'
fake 95 50 1
# Measure CPU time (user+sys), not wall time: on a loaded machine wall time
# reflects the scheduler, not the hook's own cost.
hook PostToolUse '{"session_id":"perf","tool_name":"Read","tool_use_id":"p0"}' >/dev/null  # first call emits the playbook
ms=$( { /usr/bin/time -p bash -c 'for i in 1 2 3 4 5 6 7 8 9 10; do printf "%s" "{\"session_id\":\"perf\",\"tool_name\":\"Read\",\"tool_use_id\":\"p$i\"}" | "$0" hook PostToolUse >/dev/null; done' "$LG"; } 2>&1 >/dev/null \
  | awk '/^(user|sys)/{s+=$2} END{printf "%d", s*100}')
check "PostToolUse hook averages < 150ms CPU (got ${ms}ms)" '[ "$ms" -lt 150 ]'

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
