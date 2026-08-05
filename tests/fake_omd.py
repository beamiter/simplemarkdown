#!/usr/bin/env python3
"""A stand-in for `omd`, for testing the external-preview supervisor.

The real thing pulls in a web server, a file watcher and a clipboard stack;
none of that is what simplemarkdown's side of the seam has to get right.  What
matters is that the plugin finds a free port, binds one server per buffer,
hands the browser the matching URL, and reaps the process afterwards — and all
of that is observable from a script that just holds a listening socket.

Usage mirrors omd's:
  fake_omd.py [--host H] [--port P] [--static-mode] [--clipboard] FILE

Server mode binds the port and serves a trivial HTTP response until killed.
Static mode prints the path it would have opened and exits.

Environment
  FAKE_OMD_FAIL   exit immediately with this status instead of serving
  FAKE_OMD_LOG    append one line per invocation to this file
"""

import argparse
import http.server
import os
import sys


def log(message):
    path = os.environ.get("FAKE_OMD_LOG", "")
    if path:
        with open(path, "a") as handle:
            handle.write(message + "\n")


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("file", nargs="?")
    parser.add_argument("-H", "--host", default="127.0.0.1")
    parser.add_argument("-P", "--port", type=int, default=3030)
    parser.add_argument("-s", "--static-mode", action="store_true")
    parser.add_argument("-C", "--clipboard", action="store_true")
    args = parser.parse_args()

    log(f"{'static' if args.static_mode else 'serve'} {args.host}:{args.port} {args.file}")

    failure = os.environ.get("FAKE_OMD_FAIL", "")
    if failure:
        print("fake omd: refusing to start", file=sys.stderr)
        return int(failure)

    if args.file and not args.clipboard and not os.path.isfile(args.file):
        print(f"fake omd: no such file: {args.file}", file=sys.stderr)
        return 1

    if args.static_mode:
        print(f"opened {args.file}")
        return 0

    body = f"<!doctype html><title>{args.file}</title>".encode()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    try:
        server = http.server.HTTPServer((args.host, args.port), Handler)
    except OSError as error:
        # Exactly what the real omd does when its port was taken between the
        # plugin's probe and the bind — the case the plugin has to report.
        print(f"fake omd: cannot bind {args.host}:{args.port}: {error}", file=sys.stderr)
        return 1

    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
