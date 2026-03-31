// test_m2.q — M2 unit tests
// Run from maestro/: /home/ilya/.kx/bin/q tests/test_m2.q

\l src/util.q
\l src/master.q
\l src/secondary.q

// ---------------------------------------------------------------------------
// Minimal test runner
// ---------------------------------------------------------------------------
.test.pass:0; .test.fail:0;

.test.assert:{[name;cond]
  $[cond;
    [.test.pass+:1; -1"  PASS: ",name];
    [.test.fail+:1; -1"  FAIL: ",name]];
  };

.test.run:{[]
  -1"\n--- Results: ",string[.test.pass]," pass, ",string[.test.fail]," fail ---";
  if[.test.fail>0; exit 1];
  };

// Helpers to reset master state tables between sections
.test.resetQueue:{[]
  `.master.taskQueue set ([taskId:`symbol$()] taskType:`symbol$(); fn:`symbol$();
    priority:`int$(); submittedTs:`timestamp$(); memHintBytes:`long$();
    timeoutMs:`int$(); retriesMax:`int$(); retryCount:`int$());
  .master.taskArgs::(0#`)!();
  };

.test.resetInFlight:{[]
  `.master.inFlight set ([taskId:`symbol$()] handle:`int$(); dispatchedTs:`timestamp$();
    startedTs:`timestamp$(); status:`symbol$());
  };

.test.resetSecondaries:{[]
  `.master.secondaries set ([handle:`int$()] pid:`int$(); host:`symbol$(); port:`int$();
    status:`symbol$(); registeredTs:`timestamp$(); lastHeartbeat:`timestamp$(); lastMem:`long$());
  };

.test.resetCompleted:{[]
  `.master.completed set ([] taskId:`symbol$(); handle:`int$(); startedTs:`timestamp$();
    finishedTs:`timestamp$(); resultRef:());
  };

.test.resetFailed:{[]
  `.master.failed set ([] taskId:`symbol$(); handle:`int$(); err:(); failedTs:`timestamp$());
  };

// ---------------------------------------------------------------------------
// genTaskId
// ---------------------------------------------------------------------------
-1"\n=== genTaskId ===";
.master.nextTaskId:0j;
t1:.master.genTaskId[];
t2:.master.genTaskId[];
t3:.master.genTaskId[];
.test.assert["returns a symbol";      -11h=type t1];
.test.assert["first id is `t1";       `t1=t1];
.test.assert["second id is `t2";      `t2=t2];
.test.assert["third id is `t3";       `t3=t3];
.test.assert["counter at 3";          3j=.master.nextTaskId];

// ---------------------------------------------------------------------------
// prepTask
// ---------------------------------------------------------------------------
-1"\n=== prepTask ===";
.master.nextTaskId:0j;

// Minimal task — only fn provided; all other fields take defaults
pt:.master.prepTask enlist[`fn]!enlist `myFunc;
.test.assert["auto taskId assigned";    -11h=type pt`taskId];
.test.assert["fn preserved";           `myFunc=pt`fn];
.test.assert["taskType defaults";       `unknown=pt`taskType];
.test.assert["priority defaults to 0";  0i=pt`priority];
.test.assert["retryCount defaults to 0";0i=pt`retryCount];
.test.assert["retriesMax defaults to 0";0i=pt`retriesMax];
.test.assert["memHintBytes null";       null pt`memHintBytes];
.test.assert["timeoutMs null";          null pt`timeoutMs];
.test.assert["submittedTs is timestamp";-12h=type pt`submittedTs];

// Explicit taskId is preserved
pt2:.master.prepTask `taskId`fn!(`myTask; `f);
.test.assert["explicit taskId kept";    `myTask=pt2`taskId];

// Caller values override defaults
pt3:.master.prepTask `fn`priority`retriesMax`taskType!(`f; 5i; 3i; `heavy);
.test.assert["priority override";       5i=pt3`priority];
.test.assert["retriesMax override";     3i=pt3`retriesMax];
.test.assert["taskType override";       `heavy=pt3`taskType];

// args is preserved whatever value
pt4:.master.prepTask `fn`args!(`f; 1 2 3);
.test.assert["args preserved";          (1 2 3)~pt4`args];
pt5:.master.prepTask `fn`args!(`f; `a`b);
.test.assert["symbol args preserved";   (`a`b)~pt5`args];

// ---------------------------------------------------------------------------
// enqueue / enqueueOne
// ---------------------------------------------------------------------------
-1"\n=== enqueue ===";
.master.nextTaskId:0j;
.test.resetQueue[];

// Single task dict (type 99h) is auto-wrapped
tids:enqueue `fn`args!(`double; 21);
.test.assert["returns 1-element list";          1=count tids];
.test.assert["returned tid is a symbol";        -11h=type first tids];
.test.assert["task inserted into queue";        1=count .master.taskQueue];
.test.assert["fn stored correctly";             `double=first exec fn from .master.taskQueue];
.test.assert["args stored in taskArgs";         21~first .master.taskArgs first exec taskId from .master.taskQueue];
.test.assert["priority defaulted to 0";         0i=first exec priority from .master.taskQueue];
.test.assert["submittedTs is timestamp";        -12h=type first exec submittedTs from .master.taskQueue];

// List of tasks
tids2:enqueue (`fn`args!(`triple; 7); `fn`args`priority!(`quad; 3; 2i));
.test.assert["list enqueue returns 2 tids";     2=count tids2];
.test.assert["queue now has 3 tasks";           3=count .master.taskQueue];
.test.assert["priorities stored";               2i in exec priority from .master.taskQueue];

// Explicit taskId is honoured
tids3:enqueue `taskId`fn!(`specTask; `specFunc);
.test.assert["explicit taskId in queue";        `specTask in exec taskId from .master.taskQueue];

// Re-enqueue same taskId updates in place (upsert semantics)
.master.nextTaskId:0j;
.test.resetQueue[];
enqueue `taskId`fn`args!(`dup; `f1; 1);
enqueue `taskId`fn`args!(`dup; `f2; 2);
.test.assert["upsert: still one row";           1=count .master.taskQueue];
.test.assert["upsert: fn updated";              `f2=first exec fn from .master.taskQueue];
.test.assert["upsert: args updated";            2~first .master.taskArgs`dup];

// ---------------------------------------------------------------------------
// dispatchTask — state transitions before/after send attempt
// ---------------------------------------------------------------------------
-1"\n=== dispatchTask ===";
.master.nextTaskId:0j;
.test.resetQueue[];
.test.resetInFlight[];
.test.resetSecondaries[];

.master.registerSecondary[42i; `pid`host`port!(1111i; `thost; 6001i)];
tid1:first enqueue `fn`args!(`myFunc; `hello`world);

// Send to fake handle 42i will fail; error handler marks secondary disconnected
// But state mutations (busy, inFlight, dequeue) happen before the send
.master.dispatchTask[42i; tid1];

.test.assert["task removed from queue";         0=count .master.taskQueue];
.test.assert["task added to inFlight";          1=count .master.inFlight];
.test.assert["inFlight status is dispatched";   `dispatched=first exec status from .master.inFlight];
.test.assert["inFlight handle is correct";      42i=first exec handle from .master.inFlight];
.test.assert["inFlight dispatchedTs set";       not null first exec dispatchedTs from .master.inFlight];
// send failure → secondary marked disconnected (expected for fake handle in unit tests)
.test.assert["send fail: secondary disconnected"; `disconnected=first exec status from .master.secondaries];

// ---------------------------------------------------------------------------
// taskStarted
// ---------------------------------------------------------------------------
-1"\n=== taskStarted ===";
.test.resetInFlight[];

// Seed inFlight with a dispatched task
`.master.inFlight upsert ([taskId:enlist `tS]
  handle:enlist 42i;
  dispatchedTs:enlist .z.p;
  startedTs:enlist 0Np;
  status:enlist `dispatched);

snap:.maestro.memSnapshot[];
taskStarted[`tS; snap];

.test.assert["status updated to running";   `running=first exec status from .master.inFlight];
.test.assert["startedTs is set";            not null first exec startedTs from .master.inFlight];

// taskStarted for unknown taskId — no crash, inFlight unchanged
taskStarted[`noSuch; snap];
.test.assert["unknown tid: one row still";  1=count .master.inFlight];

// ---------------------------------------------------------------------------
// taskFinished
// ---------------------------------------------------------------------------
-1"\n=== taskFinished ===";
.test.resetInFlight[];
.test.resetCompleted[];
.test.resetSecondaries[];

// Register secondary with handle 0i — matches .z.w in non-IPC test context
.master.registerSecondary[0i; `pid`host`port!(9999i; `fhost; 7000i)];
`.master.secondaries upsert ([handle:enlist 0i] status:enlist `busy);

`.master.inFlight upsert ([taskId:enlist `tFin]
  handle:enlist 0i;
  dispatchedTs:enlist .z.p;
  startedTs:enlist .z.p;
  status:enlist `running);

snap:.maestro.memSnapshot[];
taskFinished[`tFin; (::); snap; snap];

.test.assert["task removed from inFlight";          0=count .master.inFlight];
.test.assert["task added to completed";             1=count .master.completed];
.test.assert["completed taskId correct";            `tFin=first exec taskId from .master.completed];
.test.assert["completed finishedTs set";            not null first exec finishedTs from .master.completed];
.test.assert["completed startedTs set";             not null first exec startedTs from .master.completed];
.test.assert["secondary status back to idle";       `idle=first exec status from .master.secondaries];
.test.assert["secondary lastMem updated";           not null first exec lastMem from .master.secondaries];

// taskFinished for a taskId not in inFlight is a no-op
taskFinished[`ghost; (::); snap; snap];
.test.assert["unknown tid: completed count unchanged"; 1=count .master.completed];

// ---------------------------------------------------------------------------
// taskFailed
// ---------------------------------------------------------------------------
-1"\n=== taskFailed ===";
.test.resetInFlight[];
.test.resetFailed[];
`.master.secondaries upsert ([handle:enlist 0i] status:enlist `busy);

`.master.inFlight upsert ([taskId:enlist `tFail]
  handle:enlist 0i;
  dispatchedTs:enlist .z.p;
  startedTs:enlist .z.p;
  status:enlist `running);

taskFailed[`tFail; "task blew up"; snap; snap];

.test.assert["task removed from inFlight";      0=count .master.inFlight];
.test.assert["task added to failed";            1=count .master.failed];
.test.assert["failed taskId correct";           `tFail=first exec taskId from .master.failed];
.test.assert["failed err stored";               "task blew up"~first exec err from .master.failed];
.test.assert["failed failedTs set";             not null first exec failedTs from .master.failed];
.test.assert["secondary back to idle";          `idle=first exec status from .master.secondaries];

// taskFailed for unknown taskId — no crash
taskFailed[`ghost; "err"; snap; snap];
.test.assert["unknown tid: failed count unchanged"; 1=count .master.failed];

// ---------------------------------------------------------------------------
// dispatch — matching idle secondaries to pending tasks
// ---------------------------------------------------------------------------
-1"\n=== dispatch ===";
.master.nextTaskId:0j;
.test.resetQueue[];
.test.resetInFlight[];
.test.resetSecondaries[];

// Empty system — no crash
.master.dispatch[];
.test.assert["empty dispatch: no crash";    1b];
.test.assert["empty dispatch: queue empty"; 0=count .master.taskQueue];

// No tasks, one idle secondary — no crash, nothing dispatched
.master.registerSecondary[55i; `pid`host`port!(2222i; `dhost; 6002i)];
.master.dispatch[];
.test.assert["no tasks: inFlight empty";    0=count .master.inFlight];

// One task, one idle secondary — dispatch (send fails on fake handle)
tid:first enqueue `fn`args!(`someFunc; "hello");
.master.dispatch[];
.test.assert["task moved to inFlight";      1=count .master.inFlight];
.test.assert["task removed from queue";     0=count .master.taskQueue];
.test.assert["inFlight tid matches";        tid in exec taskId from .master.inFlight];

// No idle secondaries (all disconnected after failed send) — no-op
.master.dispatch[];
.test.assert["no idle secondary: inFlight unchanged"; 1=count .master.inFlight];

// ---------------------------------------------------------------------------
// dispatch — priority ordering
// ---------------------------------------------------------------------------
-1"\n=== dispatch priority ordering ===";
.master.nextTaskId:0j;
.test.resetQueue[];
.test.resetInFlight[];
.test.resetSecondaries[];

// One idle secondary
.master.registerSecondary[66i; `pid`host`port!(3333i; `phost; 6003i)];

// Enqueue low-priority task first, then high-priority
tidLo:first enqueue `fn`priority!(`loFunc; 1i);
tidHi:first enqueue `fn`priority!(`hiFunc; 99i);

// Only one idle secondary — should get the high-priority task
.master.dispatch[];
dispatched:first exec taskId from .master.inFlight;
.test.assert["high priority task dispatched";   dispatched=tidHi];
.test.assert["low priority task still queued";  tidLo in exec taskId from .master.taskQueue];

// ---------------------------------------------------------------------------
// secondary: runTask execution logic
// Test the protected execution pattern that runTask uses, without IPC
// (Full round-trip secondary <-> master is covered by integration tests)
// ---------------------------------------------------------------------------
-1"\n=== secondary runTask execution logic ===";

// Define test task functions
double:{[x] x*2};
alwaysFails:{[x] '"deliberate error: ",string x};
returnsDict:{[x] `a`b!(x; x+1)};

execTask:{[task] @[{(1b; (value x`fn) x`args)}; task; {(0b; x)}]};

// Success: integer result
r1:execTask `fn`args!(`double; 7);
.test.assert["success: ok flag true";           first r1];
.test.assert["success: result correct";         14=last r1];

// Success: dict result
r2:execTask `fn`args!(`returnsDict; 10);
.test.assert["dict result: ok flag true";       first r2];
.test.assert["dict result: type correct";       99h=type last r2];
.test.assert["dict result: values correct";     10 11~(last r2)`a`b];

// Failure: task throws
r3:execTask `fn`args!(`alwaysFails; 42);
.test.assert["failure: ok flag false";          not first r3];
.test.assert["failure: err is a string";        10h=type last r3];
.test.assert["failure: err content";            0<count (last r3) ss "deliberate error"];

// Failure: function does not exist
r4:execTask `fn`args!(`noSuchFunc9999; 0);
.test.assert["missing fn: ok flag false";       not first r4];
.test.assert["missing fn: err is a string";     10h=type last r4];

// ---------------------------------------------------------------------------
.test.run[];
