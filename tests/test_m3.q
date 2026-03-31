// test_m3.q — M3 unit tests: memory snapshots + global cap gating
// Run from maestro/: /home/ilya/.kx/bin/q tests/test_m3.q

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

// Reset helpers
.test.resetSecondaries:{[]
  `.master.secondaries set ([handle:`int$()] pid:`int$(); host:`symbol$(); port:`int$();
    status:`symbol$(); registeredTs:`timestamp$(); lastHeartbeat:`timestamp$(); lastMem:`long$());
  };

.test.resetMemState:{[]
  .master.memSamples::(0#`)!();
  .master.schedulerPausedSince::0Np;
  };

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

// ---------------------------------------------------------------------------
// memSnapshot — rss field added in M3
// ---------------------------------------------------------------------------
-1"\n=== memSnapshot (M3 rss field) ===";
snap:.maestro.memSnapshot[];

.test.assert["has rss key";         `rss in key snap];
.test.assert["rss is long type";    -7h=type snap`rss];
.test.assert["rss is null when useOsRss=0b"; null snap`rss];
.test.assert["existing keys intact — ts";       `ts in key snap];
.test.assert["existing keys intact — heapUsed"; `heapUsed in key snap];
.test.assert["existing keys intact — pid";      `pid in key snap];

// ---------------------------------------------------------------------------
// useOsRss / osRss
// ---------------------------------------------------------------------------
-1"\n=== useOsRss / osRss ===";

// osRss for own pid should return a positive long on Linux
rssVal:.maestro.osRss .z.i;
.test.assert["osRss returns long";          -7h=type rssVal];
.test.assert["osRss non-null for live pid"; not null rssVal];
.test.assert["osRss positive for live pid"; rssVal>0j];

// Bad pid should return null without error
badRss:.maestro.osRss 999999999i;
.test.assert["osRss returns null for bad pid"; null badRss];

// useOsRss=1b should populate rss field
.maestro.useOsRss:1b;
snapRss:.maestro.memSnapshot[];
.test.assert["rss populated when useOsRss=1b"; not null snapRss`rss];
.test.assert["rss>0 when useOsRss=1b";         snapRss[`rss] > 0j];
.maestro.useOsRss:0b;  // restore

// ---------------------------------------------------------------------------
// recordMemSample
// ---------------------------------------------------------------------------
-1"\n=== recordMemSample ===";
.test.resetMemState[];

snap1:.maestro.memSnapshot[];
snap2:.maestro.memSnapshot[];

// First sample for a new key
.master.recordMemSample[`master; snap1];
.test.assert["master key created";          `master in key .master.memSamples];
.test.assert["one sample stored";           1=count .master.memSamples[`master]];
.test.assert["stored sample is snap1";      snap1~first .master.memSamples[`master]];

// Second sample prepended (newest first)
.master.recordMemSample[`master; snap2];
.test.assert["two samples stored";          2=count .master.memSamples[`master]];
.test.assert["newest is first";             snap2~first .master.memSamples[`master]];
.test.assert["oldest is second";            snap1~last  .master.memSamples[`master]];

// Different keys are independent
.master.recordMemSample[`100; snap1];
.test.assert["separate key stored";         `100 in key .master.memSamples];
.test.assert["master count unchanged at 2"; 2=count .master.memSamples[`master]];

// Ring buffer cap: set maxN to 3, push 4 samples
.test.resetMemState[];
old:.master.cfg`memHistoryMaxN;
.master.cfg[`memHistoryMaxN]:3i;
s1:.maestro.memSnapshot[]; .master.recordMemSample[`master; s1];
s2:.maestro.memSnapshot[]; .master.recordMemSample[`master; s2];
s3:.maestro.memSnapshot[]; .master.recordMemSample[`master; s3];
s4:.maestro.memSnapshot[]; .master.recordMemSample[`master; s4];
.test.assert["ring buffer caps at maxN";    3=count .master.memSamples[`master]];
.test.assert["oldest sample dropped";       not s1~last .master.memSamples[`master]];
.test.assert["newest sample at front";      s4~first .master.memSamples[`master]];
.master.cfg[`memHistoryMaxN]:old;  // restore

// ---------------------------------------------------------------------------
// totalMemUsed
// ---------------------------------------------------------------------------
-1"\n=== totalMemUsed ===";
.test.resetMemState[];
.test.resetSecondaries[];

// No samples, no secondaries → 0
.test.assert["zero with no data"; 0j=.master.totalMemUsed[]];

// Master only
masterSnap:`ts`pid`heapUsed`heap`mapped`syms`symw`rss!(
  .z.p; .z.i; 500000j; 1000000j; 0j; 100j; 1000j; 0Nj);
.master.recordMemSample[`master; masterSnap];
.test.assert["master-only total";    500000j=.master.totalMemUsed[]];

// Add a secondary with known lastMem
.master.registerSecondary[10i; `pid`host`port!(1001i; `h1; 6001i)];
`.master.secondaries upsert ([handle:enlist 10i] lastMem:enlist 200000j);
.test.assert["master+secondary total"; 700000j=.master.totalMemUsed[]];

// Disconnected secondary excluded
`.master.secondaries upsert ([handle:enlist 10i] status:enlist `disconnected);
.test.assert["disconnected secondary excluded"; 500000j=.master.totalMemUsed[]];

// Null lastMem excluded
`.master.secondaries upsert ([handle:enlist 10i] status:enlist `idle; lastMem:enlist 0Nj);
.test.assert["null lastMem excluded"; 500000j=.master.totalMemUsed[]];

// Multiple secondaries summed
.master.registerSecondary[11i; `pid`host`port!(1002i; `h2; 6002i)];
`.master.secondaries upsert ([handle:enlist 10i] lastMem:enlist 100000j);
`.master.secondaries upsert ([handle:enlist 11i] lastMem:enlist 150000j);
.test.assert["two secondaries summed"; 750000j=.master.totalMemUsed[]];

// ---------------------------------------------------------------------------
// updateHeartbeat → recordMemSample
// ---------------------------------------------------------------------------
-1"\n=== updateHeartbeat records memory sample ===";
.test.resetMemState[];
.test.resetSecondaries[];
.master.registerSecondary[20i; `pid`host`port!(2001i; `hb; 7000i)];

hbSnap:.maestro.memSnapshot[];
.master.updateHeartbeat[20i; hbSnap];
.test.assert["sample recorded for handle 20"; (`$"20") in key .master.memSamples];
.test.assert["one sample stored";              1=count .master.memSamples[`$"20"]];
.test.assert["sample matches snapshot";        hbSnap~first .master.memSamples[`$"20"]];

// Second heartbeat prepended
hbSnap2:.maestro.memSnapshot[];
.master.updateHeartbeat[20i; hbSnap2];
.test.assert["two samples after second hb";    2=count .master.memSamples[`$"20"]];
.test.assert["newer snap at front";            hbSnap2~first .master.memSamples[`$"20"]];

// Unknown handle — no crash, no entry added
.master.updateHeartbeat[99i; hbSnap];
.test.assert["unknown handle ignored";         not (`$"99") in key .master.memSamples];

// ---------------------------------------------------------------------------
// taskFinished → records snapAfter in memSamples
// ---------------------------------------------------------------------------
-1"\n=== taskFinished records memory sample ===";
.test.resetMemState[];
.test.resetSecondaries[];
.test.resetInFlight[];
`.master.completed set ([] taskId:`symbol$(); handle:`int$(); startedTs:`timestamp$();
  finishedTs:`timestamp$(); resultRef:());

// Register secondary on handle 0i (matches .z.w in unit-test context)
.master.registerSecondary[0i; `pid`host`port!(9000i; `fh; 8000i)];
`.master.secondaries upsert ([handle:enlist 0i] status:enlist `busy);
`.master.inFlight upsert ([taskId:enlist `tF]
  handle:enlist 0i; dispatchedTs:enlist .z.p; startedTs:enlist .z.p; status:enlist `running);

snapA:.maestro.memSnapshot[];
taskFinished[`tF; (::); snapA; snapA];
.test.assert["taskFinished records sample";   (`$"0") in key .master.memSamples];
.test.assert["sample is snapAfter";           snapA~first .master.memSamples[`$"0"]];

// ---------------------------------------------------------------------------
// taskFailed → records snapAfter in memSamples
// ---------------------------------------------------------------------------
-1"\n=== taskFailed records memory sample ===";
.test.resetMemState[];
.test.resetSecondaries[];
.test.resetInFlight[];
`.master.failed set ([] taskId:`symbol$(); handle:`int$(); err:(); failedTs:`timestamp$());

.master.registerSecondary[0i; `pid`host`port!(9001i; `fh2; 8001i)];
`.master.secondaries upsert ([handle:enlist 0i] status:enlist `busy);
`.master.inFlight upsert ([taskId:enlist `tErr]
  handle:enlist 0i; dispatchedTs:enlist .z.p; startedTs:enlist .z.p; status:enlist `running);

snapE:.maestro.memSnapshot[];
taskFailed[`tErr; "boom"; snapE; snapE];
.test.assert["taskFailed records sample";    (`$"0") in key .master.memSamples];
.test.assert["taskFailed sample is snapAfter"; snapE~first .master.memSamples[`$"0"]];

// ---------------------------------------------------------------------------
// Dispatch memory gate — no limit (globalMemLimitBytes=0)
// ---------------------------------------------------------------------------
-1"\n=== dispatch: no memory limit ===";
.test.resetMemState[];
.test.resetSecondaries[];
.test.resetQueue[];
.test.resetInFlight[];
.master.cfg[`globalMemLimitBytes]:0j;

.master.registerSecondary[30i; `pid`host`port!(3001i; `g1; 9000i)];
`.master.secondaries upsert ([handle:enlist 30i] status:enlist `idle);

// Enqueue a no-op task, stub dispatchTask so nothing is actually sent over IPC
.master.nextTaskId::0j;
tid:enqueue enlist `fn`taskType!(`identity; `test);

// Replace dispatchTask with a stub that records dispatches
.master.testDispatched:0;
.master.dispatchTask::{[h;t] .master.testDispatched:.master.testDispatched+1};

.master.dispatch[];
.test.assert["task dispatched with no limit"; 1=.master.testDispatched];
.test.assert["schedulerPausedSince stays null"; null .master.schedulerPausedSince];

// ---------------------------------------------------------------------------
// Dispatch memory gate — over limit → pauses dispatch
// ---------------------------------------------------------------------------
-1"\n=== dispatch: over memory limit → paused ===";
.test.resetMemState[];
.test.resetSecondaries[];
.test.resetQueue[];
.test.resetInFlight[];
.master.testDispatched:0;

// Set a tiny limit and inject a master memory sample above it
.master.cfg[`globalMemLimitBytes]:100j;
bigSnap:`ts`pid`heapUsed`heap`mapped`syms`symw`rss!(.z.p;.z.i;999j;0j;0j;0j;0j;0Nj);
.master.recordMemSample[`master; bigSnap];

.master.registerSecondary[31i; `pid`host`port!(3002i; `g2; 9001i)];
`.master.secondaries upsert ([handle:enlist 31i] status:enlist `idle);
enqueue enlist `fn`taskType!(`identity; `test);

.master.dispatch[];
.test.assert["task NOT dispatched when over limit"; 0=.master.testDispatched];
.test.assert["schedulerPausedSince is set";         not null .master.schedulerPausedSince];
.test.assert["schedulerPausedSince is a timestamp"; -12h=type .master.schedulerPausedSince];

// Second dispatch call while still over limit — pausedSince not reset
pausedTs:.master.schedulerPausedSince;
.master.dispatch[];
.test.assert["task still not dispatched";           0=.master.testDispatched];
.test.assert["pausedSince unchanged";               pausedTs=.master.schedulerPausedSince];

// ---------------------------------------------------------------------------
// Dispatch memory gate — back under limit → resumes
// ---------------------------------------------------------------------------
-1"\n=== dispatch: back under limit → resumes ===";
.master.testDispatched:0;

// Inject a master sample well under the limit
smallSnap:`ts`pid`heapUsed`heap`mapped`syms`symw`rss!(.z.p;.z.i;10j;0j;0j;0j;0j;0Nj);
.master.recordMemSample[`master; smallSnap];

.master.dispatch[];
.test.assert["task dispatched after mem falls"; 1=.master.testDispatched];
.test.assert["schedulerPausedSince cleared";    null .master.schedulerPausedSince];

// ---------------------------------------------------------------------------
// Dispatch memory gate — limit=0 with high memory → no gate applied
// ---------------------------------------------------------------------------
-1"\n=== dispatch: limit=0 disables gate ===";
.test.resetMemState[];
.test.resetSecondaries[];
.test.resetQueue[];
.test.resetInFlight[];
.master.testDispatched:0;
.master.cfg[`globalMemLimitBytes]:0j;

// Inject a huge memory sample
.master.recordMemSample[`master; bigSnap];

.master.registerSecondary[32i; `pid`host`port!(3003i; `g3; 9002i)];
`.master.secondaries upsert ([handle:enlist 32i] status:enlist `idle);
enqueue enlist `fn`taskType!(`identity; `test);

.master.dispatch[];
.test.assert["no gate with limit=0"; 1=.master.testDispatched];
.test.assert["paused stays null";    null .master.schedulerPausedSince];

// Restore dispatchTask and config to clean state
.master.dispatchTask::{[h;tid]
  task:(.master.taskQueue tid),enlist[`args]!enlist first .master.taskArgs tid;
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
.master.cfg[`globalMemLimitBytes]:0j;

// ---------------------------------------------------------------------------
// schedulerPausedSince — initial state
// ---------------------------------------------------------------------------
-1"\n=== schedulerPausedSince initial state ===";
// Already tested indirectly; verify initial value after fresh load is null
.test.assert["initial pausedSince is 0Np"; null .master.schedulerPausedSince];

.test.run[];
