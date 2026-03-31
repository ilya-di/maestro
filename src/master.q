/ maestro - master.q
/ Master process: task queue, scheduling, memory-aware dispatch
/ Covers M1 (IPC/registration), M2 (task queue/dispatch), M3 (memory gating)

\d .mst

/ ============================================================================
/ State
/ ============================================================================

/ Secondary registry
secondaries:([handle:`int$()] pid:`int$(); host:(); port:`int$();
  status:`symbol$(); lastHeartbeat:`timestamp$(); lastMem:`long$();
  connectedTs:`timestamp$(); currentTaskId:`symbol$())

/ Task queue
tasks:([taskId:`symbol$()] taskType:`symbol$(); payload:(); priority:`int$();
  submittedTs:`timestamp$(); memHintBytes:`long$(); timeoutMs:`int$();
  retriesMax:`int$(); status:`symbol$(); assignedHandle:`int$();
  startedTs:`timestamp$(); completedTs:`timestamp$(); dispatchedTs:`timestamp$();
  retryCount:`int$(); error:(); resultRef:())

/ Memory time-series samples (last N snapshots for observability)
memSamples:([] ts:`timestamp$(); source:`symbol$(); pid:`int$(); rss:`long$())

/ Per-taskType rolling memory estimates
taskTypeStats:(`symbol$())!()

/ Scheduler state: `stopped `running `paused
state:`stopped

/ ============================================================================
/ Public API
/ ============================================================================

/ Start the master process
start:{[]
  port:system "p";
  if[0i=port;
    -2 "ERROR: Master must listen on a port. Start with: q start_master.q -p PORT";
    exit 1];
  .log.init "master";
  system "mkdir -p ",.cfg.active`resultDir;
  state::`running;
  .log.info "Master started on port ",string port;
  if[.cfg.active`spawnSecondaries; spawnSecondaries[]];
  / Start scheduling timer
  system "t ",string .cfg.active`dispatchIntervalMs;
  .log.info "Scheduler started (",string[.cfg.active`dispatchIntervalMs],"ms interval)";
  }

/ Stop the master - halt scheduler, optionally kill secondaries
stop:{[]
  system "t 0";
  state::`stopped;
  / Kill all connected secondaries
  pids:exec pid from secondaries where status=`connected;
  {killSecondary x} each pids;
  .log.info "Master stopped";
  .log.close[];
  }

/ Enqueue tasks. Accepts a table with at minimum: taskId, taskType, payload
enqueue:{[t]
  if[99h=type t; t:enlist t];                           / single dict -> table
  if[not 98h=type t; '"enqueue expects a table or dict"];
  n:count t;
  c:cols t;
  / Validate required columns
  if[not all `taskId`taskType`payload in c;
    '"tasks must have taskId, taskType, payload columns"];
  / Fill optional columns with defaults
  if[not `priority     in c; t:update priority:0i from t];
  if[not `memHintBytes in c; t:update memHintBytes:0Nj from t];
  if[not `timeoutMs    in c; t:update timeoutMs:.cfg.active`taskTimeoutMsDefault from t];
  if[not `retriesMax   in c; t:update retriesMax:.cfg.active`retriesMaxDefault from t];
  / Add internal tracking columns
  t:update submittedTs:.z.P, status:`queued, assignedHandle:0Ni,
    startedTs:0Np, completedTs:0Np, dispatchedTs:0Np, retryCount:0i from t;
  / General-type columns: error and resultRef
  t:t,'([] error:n#enlist ""; resultRef:n#enlist "");
  / Upsert into task queue
  `.mst.tasks upsert t;
  .log.info "Enqueued ",string[n]," task(s)";
  n
  }

/ Print and return a status snapshot
status:{[]
  totalMem:totalMemUsed[];
  limit:.cfg.active`globalMemLimitBytes;
  headroom:limit-totalMem;
  qs:`total`queued`dispatched`running`done`failed!(
    count tasks;
    exec count i from tasks where status=`queued;
    exec count i from tasks where status=`dispatched;
    exec count i from tasks where status=`running;
    exec count i from tasks where status=`done;
    exec count i from tasks where status=`failed);
  -1 "";
  -1 "=== MAESTRO STATUS ===";
  -1 "Scheduler : ",string state;
  -1 "Memory    : ",.mem.fmtBytes[totalMem]," / ",.mem.fmtBytes[limit],
    " (headroom: ",.mem.fmtBytes[headroom],")";
  -1 "";
  -1 "--- Secondaries ---";
  show select handle, pid, port, status, currentTaskId,
    mem:.mem.fmtBytes each lastMem from secondaries;
  -1 "";
  -1 "--- Tasks ---";
  -1 "Total: ",string[qs`total]," | Queued: ",string[qs`queued],
    " | Running: ",string[(qs`dispatched)+qs`running],
    " | Done: ",string[qs`done]," | Failed: ",string[qs`failed];
  if[0<count taskTypeStats;
    -1 "";
    -1 "--- Task Type Memory Estimates ---";
    {[k] s:taskTypeStats k;
      -1 "  ",string[k],": avg=",.mem.fmtBytes[s`avgMem],
        " max=",.mem.fmtBytes[s`maxMem]," (n=",string[s`count],")"
    } each key taskTypeStats;
  ];
  -1 "";
  `queueStats`memTotal`memLimit`headroom`state!(qs;totalMem;limit;headroom;state)
  }

/ ============================================================================
/ IPC callbacks (called by secondaries via async)
/ ============================================================================

/ Secondary announces itself after connecting
secondaryHello:{[info]
  h:.z.w;
  .log.info "Secondary registered: pid=",string[info`pid],
    " host=",info[`host]," port=",string info`port;
  `.mst.secondaries upsert
    `handle`pid`host`port`status`lastHeartbeat`lastMem`connectedTs`currentTaskId!
    (h; info`pid; info`host; info`port; `connected; .z.P; 0Nj; .z.P; `);
  }

/ Secondary confirms it has started a task
taskStarted:{[tid;snapshot]
  .log.info "Task running: ",string tid;
  if[tid in exec taskId from tasks;
    tasks[tid;`status]:`running;
    tasks[tid;`startedTs]:.z.P;
  ];
  }

/ Secondary reports successful completion (sends resultRef, not data)
taskFinished:{[tid;resultRef;snapPre;snapPost;snapGc]
  h:.z.w;
  .log.info "Task done: ",string[tid]," result=",resultRef;
  if[not tid in exec taskId from tasks;
    .log.warn "taskFinished for unknown task: ",string tid; :(::)];
  / Update task record
  tasks[tid;`status]:`done;
  tasks[tid;`completedTs]:.z.P;
  tasks[tid;`resultRef]:resultRef;
  / Free secondary
  update currentTaskId:`, lastMem:snapGc`rss from `.mst.secondaries where handle=h;
  / Update memory estimates for this task type
  ttype:tasks[tid;`taskType];
  memDelta:0j|snapPost[`rss]-snapPre`rss;
  updateTypeStats[ttype;memDelta];
  }

/ Secondary reports task failure
taskFailed:{[tid;err;snapPre;snapPost;snapGc]
  h:.z.w;
  .log.error "Task failed: ",string[tid]," error=",err;
  / Free secondary
  update currentTaskId:`, lastMem:snapGc`rss from `.mst.secondaries where handle=h;
  / Attempt requeue (respects retry limits)
  requeueTask[tid;err];
  }

/ Secondary heartbeat (sent when idle)
secondaryHeartbeat:{[pid;snapshot]
  update lastHeartbeat:.z.P, lastMem:snapshot`rss
    from `.mst.secondaries where pid=pid;
  }

/ ============================================================================
/ Scheduling (timer-driven)
/ ============================================================================

/ Main tick - called every dispatchIntervalMs
tick:{[]
  if[state=`stopped; :(::)];
  pollMem[];
  checkHeartbeats[];
  checkTimeouts[];
  dispatch[];
  }

/ Poll memory for master and all connected secondaries via /proc
pollMem:{[]
  / Master RSS
  masterRss:.mem.pidRss .z.i;
  if[not null masterRss;
    `.mst.memSamples upsert `ts`source`pid`rss!(.z.P;`master;.z.i;masterRss)];
  / Secondary RSS (external - works even when secondary is busy)
  secs:select handle, pid from secondaries where status=`connected;
  if[0=count secs; :(::)];
  {[s]
    rss:.mem.pidRss s`pid;
    if[not null rss;
      `.mst.secondaries upsert `handle`lastMem!(s`handle;rss);
      `.mst.memSamples upsert `ts`source`pid`rss!(.z.P;`$"sec-",string s`pid;s`pid;rss)
    ];
  } each secs;
  / Keep only last 10000 samples
  if[10000<n:count memSamples; memSamples::neg[10000]#memSamples];
  }

/ Detect dead secondaries by heartbeat timeout + PID check
checkHeartbeats:{[]
  now:.z.P;
  timeout:.cfg.active`heartbeatTimeoutMs;
  stale:select from secondaries where status=`connected,
    (("j"$now-lastHeartbeat) div 1000000) > timeout;
  if[0=count stale; :(::)];
  {[s]
    alive:0<count @[system;"kill -0 ",string[s`pid]," 2>/dev/null && echo alive";{[e]()}];
    if[not alive;
      .log.warn "Secondary pid=",string[s`pid]," unresponsive (heartbeat timeout)";
      handleDisconnect s`handle;
    ];
  } each stale;
  }

/ Detect timed-out tasks, kill the responsible secondary
checkTimeouts:{[]
  now:.z.P;
  active:select from tasks where status in `dispatched`running, not null dispatchedTs;
  if[0=count active; :(::)];
  {[now;t]
    elapsed:("j"$now-t`dispatchedTs) div 1000000;
    if[elapsed>t`timeoutMs;
      tid:t`taskId;
      .log.warn "Task ",string[tid]," timed out (",string[elapsed],"ms)";
      / Mark failed before killing (handleDisconnect checks status)
      tasks[tid;`status]:`failed;
      tasks[tid;`completedTs]:now;
      tasks[tid;`error]:"Timeout after ",string[elapsed],"ms";
      / Kill the secondary running it
      secs:select from secondaries where currentTaskId=tid;
      if[0<count secs;
        killSecondary (first secs)`pid;
      ];
    ];
  }[now] each active;
  }

/ Core dispatch loop: assign queued tasks to idle secondaries if memory allows
dispatch:{[]
  if[not state=`running; :(::)];
  / Global memory check
  totalMem:totalMemUsed[];
  headroom:.cfg.active[`globalMemLimitBytes]-totalMem;
  if[headroom<.cfg.active`dispatchWatermarkBytes;
    .log.warn "Dispatch paused: memory ",.mem.fmtBytes[totalMem],
      " (headroom ",.mem.fmtBytes[headroom]," < watermark ",.mem.fmtBytes[.cfg.active`dispatchWatermarkBytes],")";
    :(::)];
  / Get idle secondaries
  idle:0!select from secondaries where status=`connected, null currentTaskId;
  if[0=count idle; :(::)];
  / Get queued tasks sorted by priority desc, then submission time asc
  queued:0!`priority xdesc `submittedTs xasc select from tasks where status=`queued;
  if[0=count queued; :(::)];
  / Pair up and dispatch
  n:min(count idle; count queued);
  i:0;
  while[i<n;
    dispatchOne[queued i; idle i];
    i+:1;
  ];
  }

/ ============================================================================
/ Internal helpers
/ ============================================================================

/ Dispatch a single task to a single secondary
dispatchOne:{[task;sec]
  tid:task`taskId;
  h:sec`handle;
  / Per-task headroom check (V2 scheduler)
  predicted:predictMem task;
  if[not null predicted;
    headroom:.cfg.active[`globalMemLimitBytes]-totalMemUsed[];
    if[predicted>headroom*.cfg.active`headroomSafetyFactor;
      .log.info "Skipping ",string[tid]," (predicted ",.mem.fmtBytes[predicted],
        " > headroom ",.mem.fmtBytes[headroom],")";
      :(::)];
  ];
  / Build message (only fields the secondary needs)
  msg:`taskId`taskType`payload`timeoutMs!(tid;task`taskType;task`payload;task`timeoutMs);
  / Send async
  ok:.[{neg[x](`.sec.runTask;y);1b};(h;msg);{[e].log.error "Send failed: ",e;0b}];
  if[not ok; :(::)];
  / Update state
  tasks[tid;`status]:`dispatched;
  tasks[tid;`assignedHandle]:h;
  tasks[tid;`dispatchedTs]:.z.P;
  `.mst.secondaries upsert `handle`currentTaskId!(h;tid);
  .log.info "Dispatched ",string[tid]," -> secondary pid=",string sec`pid;
  }

/ Handle secondary disconnection
handleDisconnect:{[h]
  rows:select from secondaries where handle=h;
  if[0=count rows; :(::)];
  r:first rows;
  .log.warn "Secondary disconnected: pid=",string[r`pid]," port=",string r`port;
  / Mark disconnected and clear task assignment
  `.mst.secondaries upsert `handle`status`currentTaskId!(h;`disconnected;`);
  / Re-queue task if it was still active
  if[not null r`currentTaskId;
    tid:r`currentTaskId;
    if[tid in exec taskId from tasks;
      st:tasks[tid;`status];
      if[st in `dispatched`running;
        .log.warn "Re-queuing task ",string tid;
        requeueTask[tid;"Secondary disconnected"];
      ];
    ];
  ];
  }

/ Re-queue a failed task (or mark permanently failed if retries exhausted)
requeueTask:{[tid;err]
  if[not tid in exec taskId from tasks;
    .log.warn "requeueTask: unknown task ",string tid; :(::)];
  rc:tasks[tid;`retryCount];
  mx:tasks[tid;`retriesMax];
  newRc:rc+1i;
  if[newRc>mx;
    .log.error "Task ",string[tid]," exhausted retries (",string[mx],")";
    tasks[tid;`status]:`failed;
    tasks[tid;`completedTs]:.z.P;
    tasks[tid;`error]:err;
    :(::)];
  .log.info "Re-queuing ",string[tid]," (attempt ",string[1i+newRc],"/",string[1i+mx],")";
  tasks[tid;`status]:`queued;
  tasks[tid;`retryCount]:newRc;
  tasks[tid;`assignedHandle]:0Ni;
  }

/ Compute total memory used: master RSS + sum of secondary RSS
totalMemUsed:{[]
  masterRss:0j^.mem.pidRss .z.i;
  secRss:exec lastMem from secondaries where status=`connected;
  masterRss+sum 0j^secRss
  }

/ Predict memory for a task: user hint -> learned estimate -> unknown
predictMem:{[task]
  if[not null task`memHintBytes; :task`memHintBytes];
  tt:task`taskType;
  if[tt in key taskTypeStats; :taskTypeStats[tt;`avgMem]];
  0Nj
  }

/ Update rolling memory statistics for a taskType
updateTypeStats:{[ttype;memDelta]
  if[not ttype in key taskTypeStats;
    taskTypeStats[ttype]::`count`totalMem`avgMem`maxMem`samples!(0j;0j;0j;0j;`long$())];
  s:taskTypeStats ttype;
  s[`count]+:1j;
  s[`totalMem]+:memDelta;
  s[`samples]:neg[20]#s[`samples],memDelta;
  s[`avgMem]:"j"$avg s`samples;
  s[`maxMem]:max s`samples;
  taskTypeStats[ttype]::s;
  }

/ Spawn configured number of secondary processes
spawnSecondaries:{[]
  n:.cfg.active`numSecondaries;
  base:.cfg.active`baseSecondaryPort;
  ports:base+til n;
  spawnOne each ports;
  .log.info "Spawning ",string[n]," secondaries (ports ",
    string[first ports],"-",string[last ports],")";
  }

/ Spawn a single secondary q process
spawnOne:{[port]
  logFile:.cfg.active[`logDir],"/secondary-",string[port],".out";
  cmd:"nohup q start_secondary.q -p ",string[port]," > ",logFile," 2>&1 &";
  .log.info "Spawning secondary on port ",string port;
  system cmd;
  }

/ Kill a secondary process by PID
killSecondary:{[pid]
  .log.warn "Killing secondary pid=",string pid;
  @[system;"kill -9 ",string pid;{[e].log.error "Kill failed: ",e}];
  }

\d .

/ ============================================================================
/ Global IPC + timer handlers (must be in root namespace)
/ ============================================================================

.z.po:{[h] .log.info "Connection opened: handle ",string h}
.z.pc:{[h] .log.info "Connection closed: handle ",string h; .mst.handleDisconnect h}
.z.ts:{.mst.tick[]}
