// test_m1.q — M1 unit tests
// Run from maestro/: /home/ilya/.kx/bin/q tests/test_m1.q

\l src/util.q
\l src/master.q

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

// ---------------------------------------------------------------------------
// memSnapshot
// ---------------------------------------------------------------------------
-1"\n=== memSnapshot ===";
snap:.maestro.memSnapshot[];

.test.assert["returns a dict";           99h=type snap];
.test.assert["has ts key";               `ts in key snap];
.test.assert["has pid key";              `pid in key snap];
.test.assert["has heapUsed key";         `heapUsed in key snap];
.test.assert["ts is timestamp";          -12h=type snap[`ts]];
.test.assert["pid matches .z.i";         snap[`pid]=.z.i];
.test.assert["heapUsed is long";         -7h=type snap[`heapUsed]];
.test.assert["heapUsed is non-negative"; snap[`heapUsed]>=0];

// ---------------------------------------------------------------------------
// Secondary registry — initial state
// ---------------------------------------------------------------------------
-1"\n=== registry initial state ===";
.test.assert["starts empty";          0=count .master.secondaries];
.test.assert["has handle col";        `handle in cols .master.secondaries];
.test.assert["has status col";        `status in cols .master.secondaries];
.test.assert["has lastHeartbeat col"; `lastHeartbeat in cols .master.secondaries];
.test.assert["has lastMem col";       `lastMem in cols .master.secondaries];

// ---------------------------------------------------------------------------
// .master.registerSecondary
// ---------------------------------------------------------------------------
-1"\n=== registerSecondary ===";
info:`pid`host`port!(12345i; `testhost; 6001i);
.master.registerSecondary[42i; info];

.test.assert["adds one row";      1=count .master.secondaries];
.test.assert["status is idle";    `idle=first exec status from .master.secondaries];
.test.assert["pid stored";        12345i=first exec pid from .master.secondaries];
.test.assert["port stored";       6001i=first exec port from .master.secondaries];
.test.assert["host stored";       `testhost=first exec host from .master.secondaries];
.test.assert["lastMem is null";   null first exec lastMem from .master.secondaries];

// Re-registering same handle updates in place (upsert, no duplicate)
.master.registerSecondary[42i; `pid`host`port!(99999i; `otherhost; 6002i)];
.test.assert["re-register: still one row"; 1=count .master.secondaries];
.test.assert["re-register: pid updated";   99999i=first exec pid from .master.secondaries];

// ---------------------------------------------------------------------------
// .master.updateHeartbeat
// ---------------------------------------------------------------------------
-1"\n=== updateHeartbeat ===";
testSnap:`ts`pid`heapUsed`heap`mapped`syms`symw!(.z.p; .z.i; 1000000j; 2000000j; 0j; 100j; 5000j);
.master.updateHeartbeat[42i; testSnap];

.test.assert["lastMem updated";       1000000j=first exec lastMem from .master.secondaries];
.test.assert["lastHeartbeat updated"; not null first exec lastHeartbeat from .master.secondaries];

// Unknown handle is a no-op
.master.updateHeartbeat[999i; testSnap];
.test.assert["unknown handle: still one row"; 1=count .master.secondaries];

// ---------------------------------------------------------------------------
// .master.markDisconnected
// ---------------------------------------------------------------------------
-1"\n=== markDisconnected ===";
.master.markDisconnected 42i;
.test.assert["sets disconnected"; `disconnected=first exec status from .master.secondaries];

// Unknown handle is a no-op
.master.markDisconnected 999i;
.test.assert["unknown handle: safe"; 1=count .master.secondaries];

// ---------------------------------------------------------------------------
// Config structure
// ---------------------------------------------------------------------------
-1"\n=== config ===";
.test.assert["cfg has port key";        `port in key .master.cfg];
.test.assert["cfg has heartbeatMs key"; `heartbeatMs in key .master.cfg];
.test.assert["port is int";             -6h=type .master.cfg[`port]];
.test.assert["heartbeatMs is int";      -6h=type .master.cfg[`heartbeatMs]];

// ---------------------------------------------------------------------------
.test.run[];
