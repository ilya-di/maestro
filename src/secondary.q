// secondary.q — maestro secondary process
// Usage: q src/secondary.q
// Then call: start[`::5555; `port`heartbeatMs!(6001i; 10000i)]

\l src/util.q

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
.secondary.masterH:0Ni;   / IPC handle to master
.secondary.port:0Ni;      / this secondary's own listening port (for metadata)

// ---------------------------------------------------------------------------
// Message handlers — invoked by master over IPC
// ---------------------------------------------------------------------------
// Master pings; respond async with a memory snapshot
heartbeat:{[x]
  snap:.maestro.memSnapshot[];
  (neg .secondary.masterH)(`secondaryHeartbeat; snap);
  };

// Master polls for memory synchronously; return snapshot
requestMem:{[x]
  .maestro.memSnapshot[]
  };

// Master sends a task for execution (async — secondary blocks until done)
// task — dict with keys: taskId, fn (symbol), args, taskType, ...
// Calls fn[args], runs .Q.gc[], reports taskFinished or taskFailed to master.
runTask:{[task]
  tid:task`taskId;
  snapBefore:.maestro.memSnapshot[];
  (neg .secondary.masterH)(`taskStarted; tid; snapBefore);
  // Protected execution: returns (1b; result) on success, (0b; errMsg) on failure
  res:@[{(1b; (value x`fn) x`args)}; task; {(0b; x)}];
  .Q.gc[];
  snapAfter:.maestro.memSnapshot[];
  $[first res;
    (neg .secondary.masterH)(`taskFinished; tid; (::); snapBefore; snapAfter);
    (neg .secondary.masterH)(`taskFailed;   tid; last res; snapBefore; snapAfter)];
  .maestro.log["INFO"; $[first res;
    "task done: ",string tid;
    "task FAIL: ",string[tid]," err: ",string last res]];
  };

// ---------------------------------------------------------------------------
// IPC dispatch
// ---------------------------------------------------------------------------
.z.pg:{[x] @[value; x; {[e] .maestro.log["ERROR";"sync msg error: ",e]; 'e}]};
.z.ps:{[x] @[value; x; {[e] .maestro.log["ERROR";"async msg error: ",e]}]};

// If master disconnects, exit — no point running without a master
.z.pc:{[h]
  if[h=.secondary.masterH;
    .maestro.log["WARN";"master disconnected, exiting"];
    exit 1];
  };

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
// masterEndpoint — e.g. `::5555 or `myhost:5555
// cfg            — dict with at least `port (this secondary's own port)
start:{[masterEndpoint;cfg]
  .secondary.port:`int$cfg`port;
  .maestro.log["INFO";"secondary connecting to master at ",string masterEndpoint];
  .secondary.masterH:hopen masterEndpoint;
  .secondary.masterH(`secondaryHello; `pid`host`port!(.z.i; .z.h; .secondary.port));
  .maestro.log["INFO";"registered with master"];
  };
