# loadguard

**Resource-aware Claude Code agents for macOS.** loadguard stops agents from saturating your Mac (pinned CPU, memory pressure, swap storms, frozen apps) without making them timid. When the machine is busy, heavy work waits in a queue and agents are told mid-run how to replan. When it's idle, they're told to use more of it.

It runs silently. It has no UI, no dashboards and no extra prompts. The one exception: when the machine is throttling, it may ask you once whether to kill a list of dead processes.

An open-source tool from [Vectorise Labs](https://github.com/vectorise-labs). MIT licensed, no telemetry, no network calls, and macOS built-ins only.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/vectorise-labs/public-tool-claude-loadguard/main/install.sh | bash
```

or inside Claude Code:

```
/plugin marketplace add vectorise-labs/public-tool-claude-loadguard
/plugin install loadguard@vectorise-loadguard
```

The plugin installs at user scope, so it applies to every project. The first session scans the machine (cores, P/E split, RAM, swap) and writes `~/.loadguard/capacity`. Its read-only commands (`loadguard status|procs|tree|locks|lock|unlock`) are approved automatically. You don't need to edit any settings.

## What it does

| When | What happens |
|---|---|
| Session start | Starts a background sampler and tells Claude the machine's capacity and current headroom. On an idle machine that means: parallelise, use `-j<cores>`. |
| Every plan, workflow or subagent spawn (`ExitPlanMode`, `Agent`, `Task`, `Workflow`) | Adds a one-line budget: how many concurrent heavy jobs fit right now, and to share browsers, docker and dev servers. |
| Heavy Bash command (builds, test suites, `docker compose up`, browsers, installs…) | Takes a heavy-job slot. When the machine is throttling or slots are full, the command **waits in the queue** (up to 60 s) until capacity frees up. If the machine is still saturated after that, the agent gets one deny with a replan instruction. A retry always goes through, so loadguard can't deadlock work. |
| Any tool call while throttling | Each agent and subagent is told once, mid-run, to replan: (1) dead processes to clean up, (2) its own footprint to consolidate, (3) heavy work to queue. When pressure clears, each one is told to return to full speed. |
| Session end | Releases slots and shared-resource locks the session held. The sampler exits once no Claude session has run for 3 minutes. |

### The three throttle responses

1. **Dead processes.** `loadguard procs` finds orphaned dev processes, meaning their parent has exited: node/python/bun, MCP servers, headless Chrome from Playwright or Puppeteer, test runners, and parents of zombies. launchd services, GUI apps and system processes are excluded. A process is never flagged on CPU use alone. Across all sessions, Claude asks you once per episode, in a single multi-select question, which to kill. Nothing is killed without your answer.
2. **Consolidate.** `loadguard tree` shows CPU and RAM per Claude session, grouped by tool family (browser, docker, dev-server, tests, mcp, node), and flags duplicates. `loadguard lock <name> "<endpoint>"` lets one agent own a shared browser, docker stack or dev server while the others reuse it. Locks release when the owning session dies.
3. **Queue.** Heavy commands share `heavy_slots` (default: the smaller of cores/2 and RAM/6 GB, minimum 2). Under pressure they run one after another. `loadguard run -- <cmd>` also kills the command's whole process group when it exits, so nothing is left running.

## The rules

Simple on purpose, and all configurable:

- **throttled:** sustained CPU ≥ 90% · CPU ≥ 80% with a run queue ≥ 3× cores · memory pressure *warn* · ≤ 20% memory available · swapping ≥ 200 pages/s · thermal CPU limit
- **severe:** CPU ≥ 97% · memory pressure *critical* · ≤ 10% memory available
- **idle:** CPU < 45%, pressure normal, > 40% available. Agents are told to use more.

**Memory on macOS.** Used RAM always looks near 100% because of caches and compression, so loadguard ignores it. It reads the kernel's own signals: `kern.memorystatus_vm_pressure_level` (normal, warn or critical, the same signal Chromium and Firefox use), `kern.memorystatus_level` (% available, as shown by `memory_pressure`), and the rate of swap-outs from `vm_stat`. Swap that's used but not growing isn't a problem.

**CPU.** The sampler reads whole-system CPU from a single long-lived `iostat` (about 0.1% of a core, versus about 3% for `top`), averaged over 15 s so short spikes don't trigger it. Without the sampler, hooks fall back to a `ps` estimate, which takes about 30 ms. Hooks read a cached file and take about 35 ms each.

## Configure

`~/.loadguard/config` (or env vars prefixed `LOADGUARD_`):

```bash
CPU_THROTTLE=90
CPU_SEVERE=97
MEM_FREE_THROTTLE=20
MEM_FREE_SEVERE=10
SWAPOUT_THROTTLE=200
QUEUE_WAIT=60           # max seconds a heavy command waits
HEAVY_SLOTS=4           # override the scanned value
HEAVY_EXTRA_REGEX='my-heavy-tool|bin/build'
DISABLE=1               # switch off without uninstalling
```

## Commands

```
loadguard status [--json]   level + metrics
loadguard procs             dead-process candidates (read-only)
loadguard tree              per-session resource use, duplicated tools
loadguard lock|unlock|locks shared-resource ownership
loadguard run -- <cmd>      queue a heavy command + clean up its process group
loadguard scan              re-measure capacity
loadguard doctor            self-check
```

## Compatibility

- macOS 12+ (Apple silicon and Intel). On other OSes the hooks stay inert.
- Bash 3.2 (the system bash). `jq` is optional.
- Doesn't depend on any other plugin or service. It works alongside other reapers (such as cc-reaper) and offload tools: anything that runs heavy work remotely simply never shows up as local load.
- State lives in `~/.loadguard/` (override with `LOADGUARD_HOME`).

## Develop

```bash
tests/test.sh                 # 45 checks, isolated state, fake metrics
claude --plugin-dir .         # try it in a session
claude plugin validate .
```
