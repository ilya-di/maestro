/ maestro - secondary.q
/ Secondary (worker) process: connects to master, executes tasks, reports back

\d .sec

masterH:0Ni          / IPC handle to master
info:()!()           / this secondary's identity (pid, host, port)
busy:0b              / true while executing a task

/ ============================================================================
/ Public API
/ ============================================================================

/ Start the secondary: connect to master, register, begin heartbeat
start:{[]
  port:system "p";
  if[0i=port;
    -2 "ERROR: Secondary must listen on a port. Start with: q start_secondary.q -p PORT";
    exit 1];
  info::`pid`host`port!(.z.i; string .z.h; port);
  .log.init "secondary-",string port;
  / Connect to master
  endpoint:`$":",.cfg.active[`masterHost],":",string .cfg.active`masterPort;
  masterH::@[hopen;endpoint;{[e] .log.error "Cannot connect to master: ",e; 0Ni}];
  if[null masterH;
    .log.error "Exiting - master unreachable at ",string endpoint;
    exit 1];
  .log.info "Connected to master (handle ",string[masterH],")";
  / Register with master
  neg[masterH](`.mst.secondaryHello;info);
  neg[masterH](::);   / flush
  .log.info "Registered with master";
  / Start heartbeat timer
  system "t ",string .cfg.active`heartbeatIntervalMs;
  .log.info "Secondary started: pid=",string[.z.i]," port=",string port;
  }

/ ============================================================================
/ Task execution (called by master via async IPC)
/ ============================================================================

/ Execute a task dispatched by the master
runTask:{[task]
  busy::1b;
  tid:task`taskId;
  .log.info "Starting task: ",string tid;
  / Pre-task memory snapshot
  snapPre:.mem.snapshot[];
  / Notify master that task is running
  neg[masterH](`.mst.taskStarted;tid;snapPre);
  neg[masterH](::);
  / Execute payload (string query or function+args list)
  r:@[{(1b;value x)};task`payload;{[e](0b;e)}];
  / Post-task snapshot (before GC)
  snapPost:.mem.snapshot[];
  / Garbage collect
  .Q.gc[];
  / Post-GC snapshot
  snapGc:.mem.snapshot[];
  gcFreed:snapPost[`rss]-snapGc`rss;
  .log.info "Task ",string[tid],
    $[r 0;" completed";" FAILED"],
    " | GC freed: ",.mem.fmtBytes 0j|gcFreed;
  / Save result to disk as kdb binary
  ref:saveResult[tid;$[r 0;r 1;r 1]];
  / Report back to master
  $[r 0;
    neg[masterH](`.mst.taskFinished;tid;ref;snapPre;snapPost;snapGc);
    neg[masterH](`.mst.taskFailed;tid;r 1;snapPre;snapPost;snapGc)
  ];
  neg[masterH](::);
  busy::0b;
  }

/ ============================================================================
/ Helpers
/ ============================================================================

/ Save a result to the configured resultDir as kdb binary
/ Returns the filename (used as resultRef by master)
saveResult:{[tid;result]
  dir:.cfg.active`resultDir;
  system "mkdir -p ",dir;
  ts:ssr[ssr[19#string .z.P;".";"-"];":";"-"];
  fname:"result-",string[tid],"-",ts;
  path:hsym`$(dir,"/",fname);
  path set result;
  .log.info "Result saved: ",fname;
  fname
  }

/ Send heartbeat to master (only when idle)
sendHeartbeat:{[]
  if[busy; :(::)];
  if[null masterH; :(::)];
  snap:.mem.snapshot[];
  neg[masterH](`.mst.secondaryHeartbeat;info`pid;snap);
  }

\d .

/ ============================================================================
/ Global handlers (root namespace)
/ ============================================================================

/ Heartbeat timer
.z.ts:{.sec.sendHeartbeat[]}

/ Detect master disconnection
.z.pc:{[h]
  if[h=.sec.masterH;
    .log.error "Lost connection to master";
    .sec.masterH::0Ni;
  ];
  }
