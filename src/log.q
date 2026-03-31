/ maestro - log.q
/ Logging module
/ Format: <timestamp> - <type> - <message>

\d .log

fh:0Ni                  / file handle for log file
processName:"maestro"   / identifies this process in log filenames

/ Format timestamp for log lines: "2026.03.30T14:23:45.123"
fmtTs:{23#ssr[string .z.P;"D";"T"]}

/ Core log writer
write:{[level;msg]
  line:fmtTs[]," - ",string[level]," - ",msg;
  if[.cfg.active`logToStdout; -1 line];
  if[.cfg.active[`logToFile] and not null fh; fh line,"\n"];
  }

/ Convenience wrappers
info:write[`INFO]
warn:write[`WARN]
error:write[`ERROR]
debug:write[`DEBUG]

/ Initialize logging - open log file
init:{[pname]
  processName::pname;
  if[.cfg.active`logToFile;
    dir:.cfg.active`logDir;
    system "mkdir -p ",dir;
    fname:dir,"/",pname,"-",ssr[string .z.D;".";"-"],".log";
    fh::hopen hsym`$fname;
    info "Log initialized: ",fname;
  ];
  }

/ Close log file handle
close:{[]
  if[not null fh; hclose fh; fh::0Ni];
  }

\d .
