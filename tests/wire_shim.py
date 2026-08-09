#!/usr/bin/env python3
"""The real daemon, with every request the plugin sends copied to a log.

Point `g:simplemarkdown_daemon_path` at this and the plugin talks to the daemon
exactly as it always does — this only listens.  It exists because the thing
worth asserting about a debounce is *what went on the wire*, and nothing on the
Vim side can be asked that: the plugin's own counters say how many replies came
back, not how many requests it decided to send.

  $SIMPLEMARKDOWN_REAL_DAEMON  the binary to hand the traffic to
  $SIMPLEMARKDOWN_WIRE_LOG     one line per request, as sent

Replies are not copied: stdout is inherited, so the daemon writes straight back
to Vim and nothing here can reorder or delay them.
"""

import os
import subprocess
import sys

real = os.environ["SIMPLEMARKDOWN_REAL_DAEMON"]
log_path = os.environ["SIMPLEMARKDOWN_WIRE_LOG"]

child = subprocess.Popen([real, *sys.argv[1:]], stdin=subprocess.PIPE)

try:
    # Unbuffered, and reopened per line: the test reads this file while Vim is
    # still running, so a line that has been sent has to be a line it can see.
    for line in sys.stdin.buffer:
        with open(log_path, "ab", buffering=0) as log:
            log.write(line)
        child.stdin.write(line)
        child.stdin.flush()
except BrokenPipeError:
    pass

try:
    child.stdin.close()
except BrokenPipeError:
    pass
sys.exit(child.wait())
