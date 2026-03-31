/ maestro - start_secondary.q
/ Secondary (worker) process entry point
/ Usage: q start_secondary.q -p 5001
/ The secondary reads masterHost/masterPort from config to connect.

/ Load framework modules (use system "l" for compatibility with spawned processes)
system "l src/config.q"
system "l src/log.q"
system "l src/mem.q"
system "l src/secondary.q"

/ Apply user config override if defined before load
if[`userConfig in key `.; .cfg.init .userConfig];

/ Start
.sec.start[]
