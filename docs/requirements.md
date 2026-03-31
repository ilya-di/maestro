# Master/Secondary Parallelisation Framework with Memory-Aware Scheduling for Task Management and Resource Control

*Created: 2026-03-02T20:31:43.565Z by Jonny Press*
*Last Updated: 2026-03-02T20:41:06.988Z by Jonny Press*
*URL: https://data-intellect.atlassian.net/wiki/spaces/TK/pages/2289205256/Master+Secondary+Parallelisation+Framework+with+Memory-Aware+Scheduling+for+Task+Management+and+Resource+Control*

---

Build a pure q parallelisation framework consisting of:
- 1 Master q process: owns the task queue, schedules tasks, tracks memory usage, and enforces a soft global RAM cap.

- N Secondary q processes: execute tasks, report status/memory to the master, and run .Q.gc[] after each task.

The framework exists because:
- peach / .z.pd give parallelism, but don't provide centralised, memory-aware load management.

- Some tasks have unknown or highly variable memory footprints, and we want to avoid launching jobs that collectively push the system into swapping / OOM / instability.

Important point- a secondary process will be "uninterruptible" when it is running, so ideally there would be an external mechanism for gathering memory stats (system call on linux).

## Goals

Master-managed task queue
- A master maintains a list of tasks and assigns them to secondaries.

- Tasks are only dispatched when the master believes enough memory headroom exists.

Memory-aware scheduling
- Track total memory usage across:
  - master process
  - each secondary process

- Support a configurable global limit, e.g. 30 GB:
  - If the total observed usage exceeds the limit, do not dispatch new tasks.
  - Resume dispatching when usage falls below the threshold.

Worker lifecycle
- Secondaries can be started by the master or pre-started and connected.

- After each task, secondary performs .Q.gc[] and reports memory again.

Operationally usable
- Clear logging, metrics, and failure handling.

- Re-queue or mark failed tasks deterministically.

## Non-Goals (Initial Version)

- Not a full TorQ component or production-grade distributed scheduler.

- Not cross-host resource management (start with single machine; multi-host optional stretch).

- Not hard real-time enforcement of RAM limits (kdb+ can allocate quickly; we're building "best effort" gating).

- Not using threads within a single process as the primary parallel mechanism (this is multi-process).

## Target Users / Use Cases

- Running a batch of "heavy" analytic tasks over large historical data where per-task memory is unpredictable.

- Preventing "parallel runaway" where launching too many tasks at once causes:
  - swapping
  - IPC timeouts
  - OS OOM kills
  - destabilisation of other workloads on the same host

## High-Level Architecture

### Components

**Master Process**
- Maintains:
  - taskQueue (pending)
  - inFlight (assigned, running)
  - completed / failed
  - Secondaries registry (handle, pid/host/port, status, lastHeartbeat, lastMem)
  - globalMemLimitBytes

- Implements scheduling loop:
  - monitor memory (poll + reports)
  - dispatch tasks when allowed
  - handle results/failures
  - backoff when over limit

**Secondary Process**
- Waits for tasks from master.

- Executes tasks in a controlled wrapper:
  - mark running
  - capture timings
  - run task
  - run .Q.gc[]
  - report memory & outcome

### Process Relationship

- q IPC connections (h:hopen ...) between master and each secondary.

- Communication can be:
  - sync for control messages (register/heartbeat/status)
  - async for task dispatch and completion callbacks

## Core Requirements

### R1: Secondary registration and health

- Each secondary must:
  - announce itself to master (register)
  - respond to periodic heartbeats (or send its own heartbeat)
  - provide a basic "capabilities" payload (optional: core count, host, build, etc.)

**Acceptance criteria**
- Master can show a live table of secondaries: connected/disconnected, last seen time, running/idle, last memory.

### R2: Task model

Define a task as a structured object (dictionary/table) with at least:
- taskId (unique)
- taskType (string/symbol, used for profiling/estimation)
- payload (the function name + args, or a callable pattern)
- priority (optional)
- submittedTs

Optional but strongly recommended:
- memHintBytes (user-provided guess; may be null)
- timeoutMs
- retriesMax

**Acceptance criteria**
- Master supports enqueueing a list of tasks.
- Tasks move through states: queued -> dispatched -> running -> done|failed.

### R3: Memory accounting

We need a consistent way to measure memory per process.

**In-process measurement**
- Secondaries and master expose a function (e.g. memSnapshot[]) that returns a struct like:
  - ts
  - heapUsed (workspace used)
  - mapped (if relevant)
  - rss (resident set size, ideally from OS if feasible)
  - free / heapAvail (if available)
  - pid

**Approach**
- Minimum viable: use q-accessible memory stats (e.g. .Q.w[]-style workspace + mapped figures).
- Better: also sample OS-level RSS via a shell call (system "...") if permitted (config flag), because RSS is what the OS enforces.

**Acceptance criteria**
- Master has a single "totalMemUsed" view: masterMem + sum(secondaryMem)
- Master stores time-series samples (even if only last N) for observability.

### R4: Global RAM budget gating (soft enforcement)

Config: globalMemLimitBytes (e.g. 30GB).

Policy:
- If totalMemUsed >= globalMemLimitBytes, do not dispatch new tasks.
- If below, dispatch tasks subject to:
  - worker availability
  - (optional) predicted per-task memory / headroom threshold

**Important nuance**
- A task can push memory above the limit after launch; we accept this.
- The goal is to avoid launching additional tasks while already above the limit.

**Acceptance criteria**
- With an artificially low limit, the scheduler visibly pauses dispatch and resumes when memory falls.

### R5: Secondary .Q.gc[] after task completion

- Secondary must always attempt .Q.gc[] after each task (success or failure).
- Secondary reports memory before task, peak during task (if measurable), and after .Q.gc[].

**Acceptance criteria**
- For repeated tasks, memory after .Q.gc[] should trend back down (not necessarily to baseline, but observable).

### R6: Scheduling algorithm

Start with a simple scheduler, then improve.

**Baseline scheduler (V1)**
- Periodic loop (e.g. every 200-1000ms):
  - refresh memory snapshots (poll or use last reported)
  - if above limit: stop dispatch
  - else: dispatch next queued tasks to idle secondaries (one per secondary)

**Improved scheduler (V2)**
- Add "headroom" logic:
  - Define headroomBytes = globalMemLimitBytes - totalMemUsed
  - Dispatch a task only if:
    - secondary is idle
    - headroomBytes > dispatchWatermarkBytes (config)
    - and (if available) taskPredictedMemBytes < headroomBytes * headroomSafetyFactor

**Learning unknown memory**
- For each taskType, maintain a rolling estimate:
  - avgMemDelta, p95MemDelta (approx)
  - use last N samples
- If memHintBytes missing, fall back to learned estimate.

**Acceptance criteria**
- Framework can run a mixed workload where some tasks are heavy and the scheduler naturally avoids over-launching.

### R7: Fault handling & retries

**Failures to consider:**
- Secondary disconnects mid-task
- Task throws an error
- Task times out
- Secondary becomes unresponsive

**Policies:**
- If secondary disconnects while running a task:
  - mark task unknown then failed (or re-queue immediately with retryCount+1)
- Support bounded retries:
  - retriesMax with exponential backoff per task
- Quarantine option:
  - if a secondary fails repeatedly, mark it unhealthy and stop scheduling to it

**Acceptance criteria**
- Kill a secondary process mid-run; master detects and re-queues tasks according to policy.

## Interfaces & Message Contracts

### Master -> Secondary

- registerSecondary[info] (if master initiates handshake)
- runTask[task] (async)
- heartbeat[] (optional ping)
- requestMem[] (polling mode)

### Secondary -> Master

- secondaryHello[info]
- taskStarted[taskId; snapshot]
- taskFinished[taskId; resultMeta; snapshotBeforeGc; snapshotAfterGc]
- taskFailed[taskId; err; snapshotBeforeGc; snapshotAfterGc]
- secondaryHeartbeat[snapshot]

**Note on results**
- For large results: avoid returning huge objects over IPC.
  Prefer writing results to a known location/table and returning a reference (path/table name/key).

## Observability

### Logs

**Master logs:**
- dispatch events
- pause/resume due to memory
- secondary connect/disconnect
- task completion/failure

**Secondary logs:**
- start/finish/fail
- .Q.gc[] invoked
- memory snapshots

### Metrics (minimum)

- queue depth
- in-flight count
- tasks done/failed
- totalMemUsed and per-process memory
- scheduling pause time due to limit
- per taskType timing + memory deltas

**Acceptance criteria**
- A single "status" function on master prints a readable snapshot:
  secondaries table + task queue stats + memory totals + scheduler state.

## Configuration

Config list (to implement as a dict or config file):
- secondaries: list of endpoints or spawn specs
- spawnSecondaries: boolean
- numSecondaries: int (if spawning)
- globalMemLimitBytes: long
- dispatchIntervalMs: int
- dispatchWatermarkBytes: long
- headroomSafetyFactor: float (e.g. 0.8)
- taskTimeoutMsDefault
- retriesMaxDefault
- useOSRss: boolean (if allowed)

## Security / Safety Considerations

- Avoid arbitrary code execution via payloads:
  - whitelist callable task functions or enforce a task registry.
- Ensure the master can't be trivially crashed by malformed task messages.
- Consider running secondaries under restricted OS users if spawning.

## Testing Plan

### Unit tests (q-level)

- task state transitions
- scheduling gating logic
- retry/backoff rules
- memory estimator updates per taskType

### Integration tests

1. Happy path: N secondaries, M tasks, all succeed.
2. Memory gating: set low limit, verify dispatch pauses/resumes.
3. Secondary kill: terminate secondary mid-task, verify re-queue.
4. Timeout: simulate long task, verify timeout handling.
5. GC verification: ensure .Q.gc[] is called and post-GC snapshot captured.

## Deliverables

**Master process**
- master.q (or module folder)
- public API:
  - start[]
  - enqueue[tasks]
  - status[]
  - stop[]

**Secondary process**
- secondary.q
- public API:
  - start[masterEndpoint; secondaryConfig]

**Examples**
- examples/ with:
  - synthetic memory-heavy tasks
  - mixed workloads
  - demo script to run with a 30GB cap (or lower for laptops)

**Documentation**
- "How it works" + config reference
- known limitations

**Short "AI usage" report**
- which parts were built with Claude (or other tools)
- where AI helped / failed
- prompts that worked well (sanitised)

## Milestones (Suggested)

1. M1: Basic master/secondary IPC + registration
2. M2: Task queue + dispatch + completion handling
3. M3: Memory snapshots + global cap gating
4. M4: Retries + secondary failure handling
5. M5: Observability (status, logs, basic metrics)
6. M6: Task memory estimation + smarter scheduling
7. M7: Packaging + examples + docs

## Stretch Goals

- Multi-host mode (secondaries on different machines)
- Secondary auto-scaling (spawn more when queue deep and memory allows)
- More robust OS memory integration (RSS, cgroups awareness, container limits)
- Priority queues and fairness (avoid starvation)
- "Reservation" model: master reserves budget for a task before dispatch

## Definition of Done

- Can run a demo workload of at least 100 tasks across 4-8 secondaries.
- With a configured global limit, the master:
  - visibly pauses dispatch when above limit
  - resumes when below
- Secondaries always .Q.gc[] after tasks and report memory snapshots.
- Failures are handled predictably (retries + clear reporting).
- Documentation is sufficient for another engineer to run the demo from scratch.
