# Maestro — Project Instructions

## What is Maestro?
Maestro is a pure q Master/Secondary parallelisation framework with memory-aware scheduling.
A single master process owns the task queue, tracks memory across all processes, and gates dispatch
based on a configurable global RAM budget. N secondary processes execute tasks, run .Q.gc[] after
each task, and report memory snapshots back to the master.

Full requirements: `docs/requirements.md`

## Project Structure
```
maestro/
├── src/
│   ├── master.q       # master process — task queue, dispatch, scheduling, status API
│   ├── secondary.q    # secondary process — task execution, .Q.gc[], memory reporting
│   ├── config.q       # configuration — all settings as q dicts
│   ├── log.q          # logging — stdout + log files, format: <timestamp> - <type> - <message>
│   └── mem.q          # memory module — snapshots, /proc/pid/status RSS, history
├── examples/
│   └── demo.q         # demo script with synthetic workloads
├── start_master.q     # startup script for master process
├── start_secondary.q  # startup script for secondary process
├── tests/             # unit and integration tests
└── docs/
    └── requirements.md
```

## Naming Conventions
- Use `master` / `secondary` (not worker/slave/node)
- Message functions follow the contracts in requirements.md:
  - Master -> Secondary: `runTask`, `heartbeat`, `requestMem`
  - Secondary -> Master: `secondaryHello`, `taskStarted`, `taskFinished`, `taskFailed`, `secondaryHeartbeat`

## Key Design Decisions
- Pure q — no external dependencies
- Memory polling: master reads `/proc/<pid>/status` using PIDs reported at registration
- Timeout enforcement: master kills secondary processes via Linux `kill`, then re-queues tasks
- Task payloads: code/queries sent over IPC (string queries or `(func;arg1;arg2)` lists)
- Port allocation: sequential from a configurable base port
- Configuration: q dicts in `config.q`
- Logging: both stdout and log files; format: `<timestamp> - <type> - <message>`
- Result storage: raw kdb binary files to configurable directory; naming: `result-<taskId>-<timestamp>`
- Memory gating is soft/best-effort (a task can push over the limit after launch; we only gate new dispatches)

## Current Progress
- M1: Basic master/secondary IPC + registration — DONE
- M2: Task queue + dispatch + completion handling — DONE
- M3: Memory snapshots + global cap gating — DONE
- M4: Retries + secondary failure handling — NEXT
- M5: Observability (status, logs, basic metrics)
- M6: Task memory estimation + smarter scheduling
- M7: Packaging + examples + docs

## Running
```
/home/ilya/.kx/bin/q start_master.q
/home/ilya/.kx/bin/q start_secondary.q
```
