"""Stand-in for api.codetime.dev used by tests/test_http.lua.

    python3 tests/mock_server.py <log file> [port]

Prints the port it listens on, then appends one JSON line per request to the
log file. A `/s/<code>` path prefix makes it answer with that status, e.g.
api_url = "http://127.0.0.1:<port>/s/401".
"""

import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log = open(sys.argv[1], "a", buffering=1)


class Handler(BaseHTTPRequestHandler):
    def handle_request(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        status, path = 200, self.path
        match = re.match(r"^/s/(\d+)(/.*)$", path)
        if match:
            status, path = int(match[1]), match[2]
        log.write(
            json.dumps(
                {
                    "method": self.command,
                    "path": path,
                    "headers": dict(self.headers),
                    "body": body,
                }
            )
            + "\n"
        )

        response = b'{"minutes": 42}' if path.startswith("/v3/users/self/minutes") else b"{}"
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    do_GET = do_POST = handle_request

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2]) if len(sys.argv) > 2 else 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
