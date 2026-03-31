/ maestro - examples/demo.q
/ Demo workload: generates and submits tasks of varying memory intensity
/
/ Usage (from a separate q session, after master + secondaries are running):
/   \l examples/demo.q
/   h:hopen `:localhost:5000
/   h (`.mst.enqueue; genTasks 20)       / submit 20 tasks
/   h (`.mst.status; (::))               / check status
/   h (`.mst.status; (::))               / poll again later

/ Generate n tasks with a mix of light, medium, and heavy workloads
genTasks:{[n]
  types:n#`light`medium`heavy`light`medium;
  payloads:{
    $[x=`light;  "sum til 100000";
      x=`medium; "a:til 1000000; r:sum a; a:0; r";
                  "a:til 5000000; b:a*a; r:sum b; a:0; b:0; r"]
    } each types;
  ([] taskId:`$"task-",/:string til n;
      taskType:types;
      payload:payloads)
  }

/ Generate n tasks that allocate specific amounts of memory (for testing gating)
genMemTasks:{[n;mbPerTask]
  elems:"j"$mbPerTask*131072;   / 1 MB ~ 131072 longs (8 bytes each)
  payloads:n#enlist "a:til ",string[elems],"; r:sum a; a:0; r";
  ([] taskId:`$"memtask-",/:string til n;
      taskType:n#enlist`memtest;
      payload:payloads;
      memHintBytes:n#enlist "j"$mbPerTask*1048576)
  }

/ Quick-start demo: submit tasks and poll status
demo:{[]
  -1 "Connecting to master on localhost:5000 ...";
  h:@[hopen;`:localhost:5000;{[e] -2 "Cannot connect: ",e; 0Ni}];
  if[null h; :(::)];
  -1 "Submitting 20 mixed tasks ...";
  h (`.mst.enqueue; genTasks 20);
  -1 "Tasks submitted. Polling status ...";
  do[3;
    system "sleep 2";
    show h (`.mst.status; (::));
  ];
  hclose h;
  -1 "Demo complete.";
  }
