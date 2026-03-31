/ maestro - start_master.q
/ Master process entry point
/ Usage: q start_master.q -p 5000
/        q start_master.q -p 5000  (with custom config loaded first)

/ Load framework modules (use system "l" for compatibility with spawned processes)
system "l src/config.q"
system "l src/log.q"
system "l src/mem.q"
system "l src/master.q"

/ Apply user config override if defined before load
/ e.g.: q -e ".userConfig:enlist[`numSecondaries]!enlist 2i" start_master.q -p 5000
if[`userConfig in key `.; .cfg.init .userConfig];

/ Start
.mst.start[]
