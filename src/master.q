// master.q — maestro master process
// Run from the maestro/ directory: q src/master.q
// Then call: start[]

\l src/util.q

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
.master.cfg:`port`heartbeatMs`globalMemLimitBytes`dispatchWatermarkBytes`memHistoryMaxN!(
  5555i; 5000i; 0j; 0j; 100i);

// ---------------------------------------------------------------------------
// State — M1: secondary registry
// ---------------------------------------------------------------------------
// Keyed by IPC handle
.master.secondaries:([handle:`int$()]
  pid:`int$();
  host:`symbol$();
  port:`int$();
  status:`symbol$();        / `idle | `busy | `disconnected
  registeredTs:`timestamp$();
  lastHeartbeat:`timestamp$();
  lastMem:`long$());        / heapUsed bytes at last heartbeat

// ---------------------------------------------------------------------------
// State — M3: memory tracking
// ---------------------------------------------------------------------------
// Per-process memory sample history.
// Keys: `master for this process; `$string[handle] for each secondary.
// Values: list of memSnapshot dicts, newest first, capped at memHistoryMaxN.
.master.memSamples:(0#`)!();

// Set to the timestamp when the scheduler was paused due to the memory limit.
// 0Np = scheduler is not paused.
.master.schedulerPausedSince:0Np;

// ---------------------------------------------------------------------------
// State — M2: task tables
// ---------------------------------------------------------------------------
.master.nextTaskId:0j;

// Pending tasks, keyed by taskId
// Note: args is stored separately in .master.taskArgs to avoid column type constraints
.master.taskQueue:([taskId:`symbol$()]
  taskType:`symbol$();
  fn:`symbol$();
  priority:`int$();
  submittedTs:`timestamp$();
  memHintBytes:`long$();
  timeoutMs:`int$();
  retriesMax:`int$();
  retryCount:`int$());

// args storage: taskId -> any q value (decoupled from table to keep types clean)
// Keyed by symbol (taskId); values are generic so any arg type is accepted
.master.taskArgs:(0#`)!();

// Tasks currently dispatched/running, keyed by taskId
.master.inFlight:([taskId:`symbol$()]
  handle:`int$();
  dispatchedTs:`timestamp$();
  startedTs:`timestamp$();
  status:`symbol$());       / `dispatched | `running

// Completed tasks (append-only)
.master.completed:([]
  taskId:`symbol$();
  handle:`int$();
  startedTs:`timestamp$();
  finishedTs:`timestamp$();
  resultRef:());            / small results inline; large results: path/reference

// Failed tasks (append-only)
.master.failed:([]
  taskId:`symbol$();
  handle:`int$();
  err:();
  failedTs:`timestamp$());

// ---------------------------------------------------------------------------
// Internal helpers — M1
// ---------------------------------------------------------------------------
.master.registerSecondary:{[h;info]
  `.master.secondaries upsert ([handle:enlist h]
    pid:enlist `int$info`pid;
    host:enlist `$string info`host;
    port:enlist `int$info`port;
    status:enlist `idle;
    registeredTs:enlist .z.p;
    lastHeartbeat:enlist .z.p;
    lastMem:enlist 0Nj);
  .maestro.log["INFO";
    "secondary registered handle=",string[h],
    " pid=",string[info`pid],
    " port=",string[info`port]];
  };

.master.updateHeartbeat:{[h;snapshot]
  if[h in exec handle from .master.secondaries;
    `.master.secondaries upsert ([handle:enlist h]
      lastHeartbeat:enlist .z.p;
      lastMem:enlist snapshot`heapUsed);
    .master.recordMemSample[`$string h; snapshot]];
  };

.master.markDisconnected:{[h]
  if[h in exec handle from .master.secondaries;
    `.master.secondaries upsert ([handle:enlist h] status:enlist `disconnected);
    .maestro.log["WARN";"secondary disconnected handle=",string h]];
  };

// ---------------------------------------------------------------------------
// Internal helpers — M2
// ---------------------------------------------------------------------------
.master.genTaskId:{[] `$"t",string .master.nextTaskId+:1j};

// Fill in defaults for any missing task fields
.master.prepTask:{[t]
  tid:$[`taskId in key t; `symbol$t`taskId; .master.genTaskId[]];
  defs:`taskType`fn`args`priority`submittedTs`memHintBytes`timeoutMs`retriesMax`retryCount!
    (`unknown; `unknown; (::); 0i; .z.p; 0Nj; 0Ni; 0i; 0i);
  t:defs,t;
  t[`taskId]:tid;
  t
  };

// Insert one prepared task dict into taskQueue; return taskId
// args is stored in .master.taskArgs (keyed dict) to avoid column type constraints
.master.enqueueOne:{[t]
  t:.master.prepTask t;
  // Store args boxed (enlist) so the dict value vector stays generic (type 0h)
  // even when tasks have different arg types.  Retrieve with: first .master.taskArgs[tid]
  @[`.master.taskArgs; t`taskId; :; enlist t`args];
  `.master.taskQueue upsert ([taskId:enlist t`taskId]
    taskType:enlist `symbol$t`taskType;
    fn:enlist `symbol$t`fn;
    priority:enlist `int$t`priority;
    submittedTs:enlist `timestamp$t`submittedTs;
    memHintBytes:enlist `long$t`memHintBytes;
    timeoutMs:enlist `int$t`timeoutMs;
    retriesMax:enlist `int$t`retriesMax;
    retryCount:enlist `int$t`retryCount);
  t`taskId
  };

// Dispatch one task to one idle secondary (h=handle, tid=taskId)
.master.dispatchTask:{[h;tid]
  // Reconstruct full task dict: table row + args from taskArgs (unbox the enlist wrapper)
  task:(.master.taskQueue tid),enlist[`args]!enlist first .master.taskArgs tid;
  // Mark secondary busy and record in inFlight before the send,
  // so state is consistent even if the send fails
  `.master.secondaries upsert ([handle:enlist h] status:enlist `busy);
  `.master.inFlight upsert ([taskId:enlist tid]
    handle:enlist h;
    dispatchedTs:enlist .z.p;
    startedTs:enlist 0Np;
    status:enlist `dispatched);
  ![`.master.taskQueue; enlist(=;`taskId;enlist tid); 0b; `$()];
  @[(neg h); (`runTask; task);
    {[h2;e]
      .maestro.log["ERROR"; "dispatch failed handle=",string[h2]," err: ",e];
      .master.markDisconnected h2
    }[h;]];
  .maestro.log["INFO"; "dispatched ",string[tid]," -> handle ",string h];
  };

// Assign pending tasks to idle secondaries (FIFO within priority).
// Memory gate: if globalMemLimitBytes > 0 and totalMemUsed >= limit, pause dispatch.
.master.dispatch:{[]
  gated:0b;
  if[.master.cfg[`globalMemLimitBytes]>0j;
    $[.master.totalMemUsed[]>=.master.cfg`globalMemLimitBytes;
      [if[null .master.schedulerPausedSince;
         .master.schedulerPausedSince:.z.p;
         .maestro.log["WARN";"scheduler paused — memory limit reached"]];
       gated:1b];
      if[not null .master.schedulerPausedSince;
         .maestro.log["INFO";"scheduler resumed after memory pause"];
         .master.schedulerPausedSince:0Np]]];
  if[gated; :(::)];
  idle:exec handle from .master.secondaries where status=`idle;
  if[0=count idle; :(::)];
  pending:exec taskId from `priority xdesc `submittedTs xasc .master.taskQueue;
  if[0=count pending; :(::)];
  n:min(count idle; count pending);
  .master.dispatchTask'[n#idle; n#pending];
  };

// ---------------------------------------------------------------------------
// Internal helpers — M3
// ---------------------------------------------------------------------------
// Prepend snap to history for key; keep only the last memHistoryMaxN entries.
.master.recordMemSample:{[skey;snap]
  hist:$[skey in key .master.memSamples; .master.memSamples skey; ()];
  hist:enlist[snap],hist;
  n:.master.cfg`memHistoryMaxN;
  if[count[hist]>n; hist:n#hist];
  @[`.master.memSamples; skey; :; hist];
  };

// Aggregate memory view: master heapUsed + sum of last-known secondary heapUsed.
// Uses lastMem column from secondaries table (updated on every heartbeat / task event).
// Returns 0j when no samples exist yet.
.master.totalMemUsed:{[]
  masterMem:0j;
  if[count .master.memSamples[`master];
    masterMem:(first .master.memSamples[`master])`heapUsed];
  mems:exec lastMem from .master.secondaries
    where status<>`disconnected,not null lastMem;
  masterMem+$[count mems; sum mems; 0j]
  };

// ---------------------------------------------------------------------------
// Message handlers — M1
// ---------------------------------------------------------------------------
// Secondary announces itself on connect
secondaryHello:{[info]
  .master.registerSecondary[.z.w; info];
  };

// Secondary replies to heartbeat ping with a memory snapshot
secondaryHeartbeat:{[snapshot]
  .master.updateHeartbeat[.z.w; snapshot];
  };

// ---------------------------------------------------------------------------
// Message handlers — M2
// ---------------------------------------------------------------------------
// Secondary confirms it has started executing the task
taskStarted:{[tid;snapBefore]
  if[tid in exec taskId from .master.inFlight;
    `.master.inFlight upsert ([taskId:enlist tid]
      startedTs:enlist .z.p;
      status:enlist `running);
    .master.updateHeartbeat[.z.w; snapBefore]];
  };

// Secondary reports successful task completion
taskFinished:{[tid;resultRef;snapBefore;snapAfter]
  h:.z.w;
  `.master.secondaries upsert ([handle:enlist h]
    status:enlist `idle;
    lastMem:enlist snapAfter`heapUsed;
    lastHeartbeat:enlist .z.p);
  .master.recordMemSample[`$string h; snapAfter];
  if[tid in exec taskId from .master.inFlight;
    row:.master.inFlight tid;
    `.master.completed insert ([]
      taskId:enlist tid;
      handle:enlist h;
      startedTs:enlist row`startedTs;
      finishedTs:enlist .z.p;
      resultRef:enlist resultRef);
    ![`.master.inFlight; enlist(=;`taskId;enlist tid); 0b; `$()]];
  .master.taskArgs:.master.taskArgs _ tid;
  .maestro.log["INFO"; "task finished: ",string tid];
  .master.dispatch[];
  };

// Secondary reports task failure (error or exception)
taskFailed:{[tid;err;snapBefore;snapAfter]
  h:.z.w;
  `.master.secondaries upsert ([handle:enlist h]
    status:enlist `idle;
    lastMem:enlist snapAfter`heapUsed;
    lastHeartbeat:enlist .z.p);
  .master.recordMemSample[`$string h; snapAfter];
  if[tid in exec taskId from .master.inFlight;
    `.master.failed insert ([]
      taskId:enlist tid;
      handle:enlist h;
      err:enlist err;
      failedTs:enlist .z.p);
    ![`.master.inFlight; enlist(=;`taskId;enlist tid); 0b; `$()]];
  .master.taskArgs:.master.taskArgs _ tid;
  .maestro.log["WARN"; "task failed: ",string[tid]," err: ",err];
  .master.dispatch[];
  };

// ---------------------------------------------------------------------------
// IPC dispatch — protected eval so a bad message can't crash the master
// ---------------------------------------------------------------------------
.z.pg:{[x] @[value; x; {[e] .maestro.log["ERROR";"sync msg error: ",e]; 'e}]};
.z.ps:{[x] @[value; x; {[e] .maestro.log["ERROR";"async msg error: ",e]}]};

// Fired when a client connection closes
.z.pc:{[h] .master.markDisconnected h};

// ---------------------------------------------------------------------------
// Timer — heartbeat all connected secondaries + dispatch pending tasks
// ---------------------------------------------------------------------------
.master.sendHeartbeats:{[]
  handles:exec handle from .master.secondaries where status<>`disconnected;
  {[h]
    @[(neg h); (`heartbeat;::);
      {[h;e] .master.markDisconnected h}[h;]]
  } each handles;
  };

.z.ts:{[]
  .master.recordMemSample[`master; .maestro.memSnapshot[]];
  .master.sendHeartbeats[];
  .master.dispatch[];
  };

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
start:{[]
  .maestro.log["INFO";"master starting on port ",string .master.cfg`port];
  system "p ",string .master.cfg`port;
  system "t ",string .master.cfg`heartbeatMs;
  .maestro.log["INFO";"master ready — call enqueue[tasks] to submit work"];
  };

// tasks — single task dict or list of task dicts
// Each task must have at least `fn (symbol). `taskId, `taskType, `args etc. are optional.
// Returns list of assigned taskIds.
enqueue:{[tasks]
  if[99h=type tasks; tasks:enlist tasks];
  tids:.master.enqueueOne each tasks;
  .maestro.log["INFO"; "enqueued ",string[count tasks]," task(s)"];
  tids
  };

status:{[]
  -1"\n=== Maestro Master Status ===";
  -1"Secondaries:";
  show .master.secondaries;
  -1"\nMemory:";
  total:.master.totalMemUsed[];
  lim:.master.cfg`globalMemLimitBytes;
  -1"  totalMemUsed:   ",string[total]," bytes";
  if[lim>0j;
    -1"  globalMemLimit: ",string[lim]," bytes";
    pct:100*total%lim;
    -1"  usage:          ",string[.Q.fmt[6;1;pct]],"%"];
  sched:$[null .master.schedulerPausedSince; "running"; "PAUSED (mem limit)"];
  -1"  scheduler:      ",sched;
  -1"\nTask Queue (",string[count .master.taskQueue]," pending):";
  if[count .master.taskQueue; show .master.taskQueue];
  -1"\nIn Flight (",string[count .master.inFlight]," tasks):";
  if[count .master.inFlight; show .master.inFlight];
  -1"\nCompleted: ",string[count .master.completed],
    "  Failed: ",string count .master.failed;
  -1"";
  };

stop:{[]
  system "t 0";
  {[h] @[hclose; h; {}]} each exec handle from .master.secondaries where status<>`disconnected;
  .maestro.log["INFO";"master stopped"];
  };
