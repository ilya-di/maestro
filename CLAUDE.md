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
│   └── util.q         # shared utilities — logging (.maestro.log), memory snapshots (.maestro.memSnapshot)
├── tests/
│   ├── test_m1.q      # M1 tests — IPC registration, heartbeat, secondary registry (30 tests)
│   ├── test_m2.q      # M2 tests — task queue, dispatch, completion handling (77 tests)
│   └── test_m3.q      # M3 tests — memory snapshots, global cap gating (51 tests)
├── examples/          # demo scripts and synthetic workloads
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
- Memory gating is soft/best-effort (a task can push over the limit after launch; we only gate new dispatches)
- Secondaries are uninterruptible during task execution — memory polling uses OS-level system calls
- Large task results should not be returned over IPC; write to a known location and return a reference

## Current Progress
- M1: Basic master/secondary IPC + registration — DONE (30 tests)
- M2: Task queue + dispatch + completion handling — DONE (77 tests)
- M3: Memory snapshots + global cap gating — DONE (51 tests)
- M4: Retries + secondary failure handling — NEXT
- M5: Observability (status, logs, basic metrics)
- M6: Task memory estimation + smarter scheduling
- M7: Packaging + examples + docs

## Running Tests
```
/home/ilya/.kx/bin/q tests/test_m1.q
/home/ilya/.kx/bin/q tests/test_m2.q
/home/ilya/.kx/bin/q tests/test_m3.q
```
