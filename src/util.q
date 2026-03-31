// util.q — shared utilities for the maestro framework

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------
// .maestro.log[level; msg]  — level is a string: "INFO", "WARN", "ERROR"
.maestro.log:{[level;msg]
  -1 (string .z.p)," [",level,"] ",msg;
  };

// ---------------------------------------------------------------------------
// Memory snapshot
// ---------------------------------------------------------------------------
// Set to 1b to read OS-level RSS from /proc/<pid>/status (Linux only).
// When disabled (default), rss field is 0Nj.
.maestro.useOsRss:0b;

// Read resident set size for a given pid from /proc/<pid>/status.
// Returns bytes as long, or 0Nj on any error.
.maestro.osRss:{[pid]
  kb:@[{first "J"$system "awk '/VmRSS/{print $2}' /proc/",string[x],"/status"}; pid; {0Nj}];
  $[null kb; 0Nj; 1024j*kb]
  };

// Returns a dict with current process memory stats.
// Keys: ts, pid, heapUsed, heap, mapped, syms, symw, rss
// heapUsed  = bytes in use in the workspace (primary scheduling signal)
// rss       = OS resident set size in bytes (0Nj when useOsRss is 0b)
.maestro.memSnapshot:{[]
  w:.Q.w[];
  rss:$[.maestro.useOsRss; .maestro.osRss .z.i; 0Nj];
  `ts`pid`heapUsed`heap`mapped`syms`symw`rss!(
    .z.p; .z.i; w`used; w`heap; w`mmap; w`syms; w`symw; rss)
  };
