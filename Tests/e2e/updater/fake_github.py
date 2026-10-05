"""Fake GitHub for the self-update tests: REST API, release asset downloads and the web fallback.

    python3 fake_github.py ROOT PORTFILE

Serves ROOT/www as static files. /<mode>/repos/<owner>/<repo>/releases[/latest] answers with
ROOT/www/api/<mode>-latest.json or <mode>-list.json ("__BASE__" is replaced by the server's URL).
Special modes: api-403 (rate limit), api-none (no releases). Binds 127.0.0.1 on a free port and writes
the port to PORTFILE.
"""
import http.server
import os
import sys

ROOT, PORTFILE = sys.argv[1], sys.argv[2]
WWW = os.path.join(ROOT, "www")


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=WWW, **kwargs)

    def log_message(self, fmt, *args):
        with open(os.path.join(ROOT, "requests.log"), "a") as log:
            log.write("%s %s\n" % (self.command, self.path))

    def base(self):
        return "http://127.0.0.1:%d" % self.server.server_address[1]

    def do_GET(self):
        path = self.path.split("?")[0]
        mode = path.strip("/").split("/", 1)[0]
        if mode.startswith("api-"):
            if mode == "api-403":
                self.send_response(403)
                self.send_header("X-RateLimit-Remaining", "0")
                self.send_header("X-RateLimit-Reset", "1791150975")
                self.end_headers()
                self.wfile.write(b'{"message":"API rate limit exceeded"}')
                return
            kind = "latest" if path.endswith("/releases/latest") else "list" if path.endswith("/releases") else None
            fixture = os.path.join(WWW, "api", "%s-%s.json" % (mode, kind))
            if mode == "api-none" or kind is None or not os.path.exists(fixture):
                self.send_response(404)
                self.end_headers()
                return
            body = open(fixture).read().replace("__BASE__", self.base()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("ETag", '"%d"' % hash(body))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORTFILE, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
