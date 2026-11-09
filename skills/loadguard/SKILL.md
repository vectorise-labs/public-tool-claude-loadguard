---
name: loadguard
description: Plan and run work so it stays effective on this Mac's CPU and memory. Use when planning parallel work, spawning subagents or workflows, running heavy commands (builds, test suites, docker, browsers, dev servers), when the machine feels slow, swaps, or freezes, or when a loadguard notice appears. Covers checking load, cleaning up dead processes, sharing browsers/docker/dev servers between agents, and queueing heavy jobs. Also covers using more parallelism when the machine is idle.
---

# loadguard: effective agents on a shared Mac

Goal: **get the work done fast without taking the machine down.** It is about effective agents, not frugal ones. If the machine has room, use it: parallelise and add workers. Hold back only when loadguard reports throttling.

`loadguard` is put on PATH at session start. If it is not found, use the absolute path from the session-start note. Its status and coordination commands skip the permission prompt only when run on their own, so don't chain or redirect them.

| Command | What it tells you |
|---|---|
| `loadguard status` | level (`idle` / `ok` / `throttled` / `severe`), CPU, memory pressure, swap, heavy slots in use |
| `loadguard procs` | likely-dead processes (orphaned dev tools, headless browsers, zombie parents). It never kills |
| `loadguard tree` | CPU/RAM per Claude session by tool family (browser, docker, dev-server, tests, mcp, node), and duplicated tools |
| `loadguard lock <name> "<endpoint>"` | claim a shared resource; if someone holds it, you get their endpoint to reuse |
| `loadguard locks` / `unlock <name>` | list or release shared resources |
| `loadguard run -- <cmd>` | queue a heavy command and kill its whole process group when it exits |

## Rules (simple on purpose)

- **Throttled** means sustained CPU ≥ 90%, CPU ≥ 80% with a run queue ≥ 3× cores, macOS memory pressure *warn*, ≤ 20% memory available, active swapping, or a thermal CPU limit. **Severe** means CPU ≥ 97%, pressure *critical*, or ≤ 10% available.
- On macOS, RAM always looks full and that's fine. The kernel's pressure level and available-memory %, and active swap-outs, are the real signals. Swap that's used but not growing isn't a problem.

## When planning (plans, workflows, fan-outs)

1. Run `loadguard status` once, or read the line loadguard already injected.
2. Size the parallelism to the heavy slots. Light work (reading, editing, searching, thinking) is never limited. Only count jobs that compile, test, run containers or drive browsers.
3. Say which agent owns each shared heavy resource (one browser, one docker stack, one dev server per project) and have the others reuse it.
4. Make every agent stop what it started (servers, containers, browsers, watchers) before it reports back.

## When loadguard says the machine is throttling

Do these three things, then carry on with the task:

1. **Dead processes.** If the notice includes a candidate list, ask the user **once**, in a single multi-select question, which to kill, then kill only those (`kill <pid>`, and `kill -9` only if it survives). Don't ask again in the same episode, and don't kill anything you weren't given. If no list was included, skip this step.
2. **Consolidate.** Run `loadguard tree`. Stop duplicates you own. Before starting a browser, docker stack or dev server, run `loadguard lock <name> "<how to connect>"`. If it is held, connect to the noted endpoint instead of starting another. Release it with `loadguard unlock <name>` when done.
3. **Queue.** Run heavy commands one at a time. While throttled, the Bash hook lets one run and holds the rest for up to 60 s. Run fewer heavy subagents at once and start the rest as earlier ones finish. Long jobs can go to the background so they don't hit the Bash timeout.

## When the machine is idle

Underuse costs time too. When the level is `idle` or `ok`, prefer parallel subagents for independent work, `make -j<cores>`, test runners with workers on, and running independent checks at the same time.
