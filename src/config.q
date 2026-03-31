/ maestro - config.q
/ Framework configuration as q dict

\d .cfg

default:`masterHost`masterPort`baseSecondaryPort`numSecondaries`spawnSecondaries`globalMemLimitBytes`dispatchIntervalMs`dispatchWatermarkBytes`headroomSafetyFactor`taskTimeoutMsDefault`retriesMaxDefault`useOSRss`resultDir`logDir`logToFile`logToStdout`heartbeatIntervalMs`heartbeatTimeoutMs!(
  "localhost";                          / masterHost
  5000i;                                / masterPort
  5001i;                                / baseSecondaryPort
  4i;                                   / numSecondaries
  1b;                                   / spawnSecondaries
  30000000000j;                         / globalMemLimitBytes (30GB)
  500i;                                 / dispatchIntervalMs
  1000000000j;                          / dispatchWatermarkBytes (1GB headroom)
  0.8;                                  / headroomSafetyFactor
  300000i;                              / taskTimeoutMsDefault (5 min)
  3i;                                   / retriesMaxDefault
  1b;                                   / useOSRss (read /proc for RSS)
  getenv[`HOME],"/maestro-results";     / resultDir
  getenv[`HOME],"/maestro-logs";        / logDir
  1b;                                   / logToFile
  1b;                                   / logToStdout
  5000i;                                / heartbeatIntervalMs
  15000i                                / heartbeatTimeoutMs
  )

/ Active configuration - starts as copy of defaults
active:default

/ Override active config with user-provided dict
init:{[userCfg]
  if[99h~type userCfg; active::default,userCfg];
  }

\d .
