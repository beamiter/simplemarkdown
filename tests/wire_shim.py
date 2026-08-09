#!/usr/bin/env python3
"""The real daemon, with every request the plugin sends copied to a log.

Point `g:simplemarkdown_daemon_path` at this and the plugin talks to the daemon
exactly as it always does — this only listens.  It exists because the thing
worth asserting about a debounce is *what went on the wire*, and nothing on the
Vim side can be asked that: the plugin's own counters say how many replies came
back, not how many requests it decided to send.

  $SIMPLEMARKDOWN_REAL_DAEMON  the binary to hand the traffic to
  $SIMPLEMARKDOWN_WIRE_LOG     one line per request, as sent
  $SIMPLEMARKDOWN_WIRE_STALL   a substring of the requests to hold back
  $SIMPLEMARKDOWN_WIRE_STALL_MS   how long to hold one, in milliseconds

The stall is what makes "a request that is still in flight" a state a test can
arrange: a matching request is logged, then held here for that long before the
daemon is given it, so anything the plugin decides while it is outstanding —
withdrawing it, most of all — happens for real rather than in a race the test
would have to win.  Holding the request rather than the reply is deliberate; a
busy daemon is exactly a request not yet answered, and *replies* are not copied
at all: stdout is inherited, so the daemon writes straight back to Vim and
nothing here can reorder or delay them.
"""

import os
import subprocess
import sys
import time

real = os.environ["SIMPLEMARKDOWN_REAL_DAEMON"]
log_path = os.environ["SIMPLEMARKDOWN_WIRE_LOG"]
stall = os.environ.get("SIMPLEMARKDOWN_WIRE_STALL", "").encode()
stall_ms = int(os.environ.get("SIMPLEMARKDOWN_WIRE_STALL_MS", "0"))

child = subprocess.Popen([real, *sys.argv[1:]], stdin=subprocess.PIPE)

try:
    # Unbuffered, and reopened per line: the test reads this file while Vim is
    # still running, so a line that has been sent has to be a line it can see.
    for line in sys.stdin.buffer:
        with open(log_path, "ab", buffering=0) as log:
            log.write(line)
        if stall and stall_ms and stall in line:
            time.sleep(stall_ms / 1000.0)
        child.stdin.write(line)
        child.stdin.flush()
except BrokenPipeError:
    pass

try:
    child.stdin.close()
except BrokenPipeError:
    pass
sys.exit(child.wait())
