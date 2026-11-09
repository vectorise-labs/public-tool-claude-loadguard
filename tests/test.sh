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
fake 99 50 1
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

echo "monitor"
rm -f "$LOADGUARD_HOME/state/metrics"
LOADGUARD_NO_MONITOR=0 LOADGUARD_SAMPLE_SECONDS=1 "$LG" monitor >/dev/null 2>&1 &
mon=$!
for i in $(seq 1 20); do grep -qs '^source=monitor' "$LOADGUARD_HOME/state/metrics" && break; sleep 0.5; done
check "monitor writes live metrics" 'grep -qs "^source=monitor" "$LOADGUARD_HOME/state/metrics"'
check "monitor records its pid" '[ "$(cat "$LOADGUARD_HOME/state/monitor.pid" 2>/dev/null)" = "$mon" ]'
kill -TERM "$mon" 2>/dev/null
for i in $(seq 1 10); do kill -0 "$mon" 2>/dev/null || break; sleep 0.3; done
check "monitor stops on SIGTERM" '! kill -0 "$mon" 2>/dev/null'
check "monitor leaves no iostat behind" '! pgrep -P "$mon" >/dev/null 2>&1 && [ ! -f "$LOADGUARD_HOME/state/monitor.pid" ]'
kill -KILL "$mon" 2>/dev/null; wait "$mon" 2>/dev/null

echo "throttled runs heavy work one at a time"
fake 95 50 1; rm -f "$LOADGUARD_HOME"/slots/*
start=$(date +%s)
out=$(LOADGUARD_QUEUE_WAIT=20 hook PreToolUse '{"session_id":"t1","tool_name":"Bash","tool_use_id":"s1","tool_input":{"command":"npm test"}}')
el=$(( $(date +%s) - start ))
check "throttled + empty queue -> runs immediately" '[ $el -le 1 ] && [ -f "$LOADGUARD_HOME/slots/s1" ]' "$out (elapsed $el)"
out=$(LOADGUARD_QUEUE_WAIT=0 hook PreToolUse '{"session_id":"t2","tool_name":"Bash","tool_use_id":"s2","tool_input":{"command":"npm test"}}')
check "throttled + one running -> next one is held" 'echo "$out" | grep -q "\"deny\""' "$out"
rm -f "$LOADGUARD_HOME"/slots/*

echo "simultaneous heavy starts cannot exceed the cap"
fake 75 50 1; . "$LOADGUARD_HOME/capacity"
for i in $(seq 1 $(( heavy_slots + 6 ))); do
  ( LOADGUARD_QUEUE_WAIT=0 hook PreToolUse '{"session_id":"h","agent_id":"a'$i'","tool_name":"Bash","tool_use_id":"h'$i'","tool_input":{"command":"npm test"}}' >/dev/null ) &
done; wait
n=$(ls "$LOADGUARD_HOME"/slots | wc -l | tr -d ' ')
check "burst of $(( heavy_slots + 6 )) gets exactly $heavy_slots slots (got $n)" '[ "$n" -eq "$heavy_slots" ]'
rm -f "$LOADGUARD_HOME"/slots/*
fake 30 60 1
for i in $(seq 1 $(( heavy_slots * 2 ))); do echo "$$ $(date +%s)" > "$LOADGUARD_HOME/slots/fill$i"; done
out=$(LOADGUARD_QUEUE_WAIT=0 hook PreToolUse '{"session_id":"h2","tool_name":"Bash","tool_use_id":"h20","tool_input":{"command":"npm test"}}')
check "idle burst is capped at twice the slots" 'echo "$out" | grep -q "\"deny\""' "$out"
rm -f "$LOADGUARD_HOME"/slots/*

echo "auto-approval is a security boundary"
fake 30 60 1
approve() { jq -cn --arg c "$1" '{session_id:"sec",tool_name:"Bash",tool_use_id:"sec",tool_input:{command:$c}}' | "$LG" hook PreToolUse | grep -q '"allow"'; }
for c in 'loadguard status' 'loadguard status --json' 'loadguard procs' 'loadguard tree' 'loadguard locks' 'loadguard doctor' 'loadguard lock browser "ws://127.0.0.1:9222"' 'loadguard unlock browser' "$ROOT/bin/loadguard status"; do
  check "approved: $c" 'approve "$c"'
done
for c in $'loadguard status\nrm -rf x' $'loadguard status\rrm x' $'loadguard status\trm' './loadguard status' '/tmp/evil/loadguard status' '../x/loadguard procs' 'loadguard status; rm x' 'loadguard status && rm x' 'loadguard status | sh' 'loadguard status > f' 'loadguard status (rm x)' 'loadguard lock a "$(rm x)"' 'loadguard lock a `rm x`' "loadguard lock a 'x'" 'loadguard lock a \\' 'loadguard status --evil' 'loadguard run -- rm x' 'loadguard hook Stop' 'loadguard monitor' 'FOO=1 loadguard status' 'xloadguard status'; do
  check "NOT approved: $(printf '%q' "$c")" '! approve "$c"'
done

jqless=$(mktemp -d); for t in cat grep sed awk ps sysctl date dirname uname mkdir rm mv tr head find wc id sleep; do ln -s "$(PATH=/usr/bin:/bin:/usr/sbin:/sbin command -v $t)" "$jqless/$t"; done
out=$(printf '%s' '{"session_id":"sec","tool_name":"Bash","tool_use_id":"sec","tool_input":{"command":"loadguard status"}}' | PATH="$jqless" /bin/bash "$LG" hook PreToolUse)
check "without jq, nothing is auto-approved" '! echo "$out" | grep -q "\"allow\""' "$out"
rm -rf "$jqless"

echo "heavy detection reads commands, not arguments"
heavy() { rm -f "$LOADGUARD_HOME"/slots/hv; jq -cn --arg c "$1" '{session_id:"hv",tool_name:"Bash",tool_use_id:"hv",tool_input:{command:$c}}' | "$LG" hook PreToolUse >/dev/null; [ -f "$LOADGUARD_HOME/slots/hv" ]; }
for c in 'npm test' 'make -j8' 'docker compose up -d' 'docker build .' 'cd a && pnpm build' 'FOO=1 pytest -x' 'cargo build' 'npx playwright test' './gradlew build' 'node --test' 'python3 -m pytest' 'bun test' 'time make' 'timeout 60 npm test' 'ls && go test ./...' '(cargo test)' $'cd a\nnpm test'; do
  check "heavy: $c" 'heavy "$c"'
done
for c in 'ls ninja' 'cat webpack.config.js' 'echo docker compose up' 'rg tsc src' 'git commit -m "make tests faster"' 'grep -r "npm test" .' 'npm view react' 'docker ps' 'go version' 'git log --grep=make'; do
  check "light: $c" '! heavy "$c"'
done
rm -f "$LOADGUARD_HOME"/slots/*

echo "sampler to notice, end to end (fake iostat, real monitor and hook)"
shim=$(mktemp -d); cat > "$shim/iostat" <<'SH'
#!/bin/bash
echo "      cpu    load average"; echo " us sy id   1m   5m   15m"
while :; do echo " 90  8  2  1.00 1.00 1.00"; sleep 0.3; done
SH
chmod +x "$shim/iostat"; rm -f "$LOADGUARD_HOME/state/metrics" "$LOADGUARD_HOME/state/episode"
PATH="$shim:$PATH" LOADGUARD_SAMPLE_SECONDS=1 "$LG" monitor >/dev/null 2>&1 &
mon=$!
for i in $(seq 1 30); do grep -qs '^level=severe' "$LOADGUARD_HOME/state/metrics" && break; sleep 0.2; done
check "98% busy from iostat classifies as severe" 'grep -qs "^level=severe" "$LOADGUARD_HOME/state/metrics"' "$(cat "$LOADGUARD_HOME/state/metrics" 2>/dev/null)"
out=$(hook PostToolUse '{"session_id":"live","tool_name":"Read","tool_use_id":"l1"}')
check "live monitor reading reaches the agent mid-run" 'valid_json "$out" && echo "$out" | grep -q "throttling"' "$out"
kill -TERM "$mon" 2>/dev/null; for i in $(seq 1 10); do kill -0 "$mon" 2>/dev/null || break; sleep 0.3; done
kill -KILL "$mon" 2>/dev/null; wait "$mon" 2>/dev/null; rm -rf "$shim"; rm -f "$LOADGUARD_HOME/state/episode"

echo "session detection"
fakebin=$(mktemp -d); mkdir -p "$fakebin/@anthropic-ai/claude-code"
cat > "$fakebin/@anthropic-ai/claude-code/cli.js" <<SH
#!/bin/bash
"$LG" lock npmtest "x" >/dev/null; "$LG" locks > "$fakebin/out.tmp"; mv "$fakebin/out.tmp" "$fakebin/out"; sleep 1
SH
chmod +x "$fakebin/@anthropic-ai/claude-code/cli.js"; "$fakebin/@anthropic-ai/claude-code/cli.js" & npmpid=$!
for i in $(seq 1 50); do [ -s "$fakebin/out" ] && break; sleep 0.1; done
check "npm-installed Claude Code is recognised as the session" 'grep -q "session $npmpid" "$fakebin/out"' "$(cat "$fakebin/out" 2>/dev/null) expected $npmpid"
wait $npmpid; rm -rf "$fakebin"; "$LG" unlock npmtest >/dev/null

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
