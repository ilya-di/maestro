/ maestro - mem.q
/ Memory utilities: in-process snapshots and OS-level RSS via /proc

\d .mem

/ In-process memory snapshot using .Q.w[] and optionally /proc
snapshot:{[]
  w:.Q.w[];
  `ts`pid`heapUsed`heapTotal`peakHeap`mapped`rss!(
    .z.P;
    .z.i;
    w`used;
    w`heap;
    w`peak;
    w`mmap;
    $[.cfg.active`useOSRss; pidRss .z.i; 0Nj]
    )
  }

/ Get RSS in bytes for a PID by reading /proc/<pid>/status (Linux)
/ Returns 0Nj on failure (process gone, /proc unavailable, etc.)
pidRss:{[pid]
  r:@[{system "awk '/^VmRSS/{print $2}' /proc/",(string x),"/status"};
    pid;
    {[e] ()}];
  if[0=count r; :0Nj];
  v:"J"$first r;
  if[null v; :0Nj];
  1024*v                / VmRSS is in kB; convert to bytes
  }

/ Format byte count for human-readable display
fmtBytes:{[b]
  if[null b; :"N/A"];
  if[b<1024;       :string[b]," B"];
  if[b<1048576;    :string["j"$b%1024]," KB"];
  if[b<1073741824; :string["j"$b%1048576]," MB"];
  string[0.01*"j"$100*b%1073741824]," GB"
  }

\d .
