"""Loopback TLS fixture for Conduck's live certificate-pinning tests.

Started by `scripts/run-live-tls-tests.sh`, never by the tests themselves: the
macOS test host is a SANDBOXED app and the App Sandbox denies `bind()`
(`PermissionError: [Errno 1]`) to the app and to every process it spawns, with
no entitlement short of `com.apple.security.network.server` — which a
client-only app must not ship just to make a test run.

Four listeners on 127.0.0.1, all bound on port 0:

  tlsA    https, EC P-256 certificate (identity 1) — the "gateway"
  tlsB    https, EC P-256 certificate (identity 1 — THE SAME KEY as tlsA),
          the cross-origin redirect target. Sharing the key is the whole point:
          a pin compare proves "same key", not "same origin", so with identical
          keys the pin cannot refuse a hop between them and ONLY the redirect
          policy can. Give them different keys and the redirect tests pass for
          the wrong reason.
  tlsRSA  https, RSA-2048 certificate (identity 2) — the second SPKI prefix
          family in the app's V1 table.
  plain   http — the scheme-downgrade redirect target.

Every request is counted under "<role> <path>" and the tally is served at
GET /__hits on tlsA, so a test can assert a redirect target was NEVER CONTACTED
rather than merely that the client reported an error.

Writes <workdir>/ports.json atomically once all four sockets are bound, then
serves until stdin closes (the parent dying is the teardown signal) or SIGTERM.
Certificates are read from <workdir> (ec-cert.pem / ec-key.pem / rsa-cert.pem /
rsa-key.pem); the runner script generates them.
"""

import collections
import http.server
import json
import os
import socketserver
import ssl
import sys
import threading

HITS = collections.Counter()
HITS_LOCK = threading.Lock()
PORTS = {}

MARKERS = {"tlsA": b"MARKER-TLS-A", "tlsB": b"LEAK-TLS-B",
           "tlsRSA": b"MARKER-TLS-RSA", "plain": b"LEAK-PLAIN"}


class NoReverseLookupServer(socketserver.ThreadingTCPServer):
    """`http.server.HTTPServer.server_bind` calls `socket.getfqdn()` on the bind
    address, and nothing is served until it returns. On a host with no reverse
    zone for 127.0.0.1 that lookup blocks until the resolver gives up — ~20 s on
    a GitHub macOS runner, and once 33 minutes here — so the ports file never
    appears and the suite fails for a reason nothing prints. Bind without the
    lookup; `server_name` is read only by the CGI handlers, which this fixture
    has none of. Same rule as every fixture under `connect/tests/`.
    """

    allow_reuse_address = 1
    daemon_threads = True

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


class Handler(http.server.BaseHTTPRequestHandler):

    role = "?"
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, status, body=b"", headers=None):
        self.send_response(status)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _route(self):
        with HITS_LOCK:
            HITS["%s %s" % (self.role, self.path)] += 1
        path = self.path

        if path == "/__hits":
            with HITS_LOCK:
                body = json.dumps(dict(HITS)).encode()
            self._send(200, body)
            return

        # Redirects the client must REFUSE, keyed by which single origin
        # component differs from the origin that answered — plus one it must
        # FOLLOW, so the policy is proven to discriminate rather than to block
        # every 3xx.
        redirects = {
            # different PORT, same host, same key
            "/redirect/cross-port":
                "https://127.0.0.1:%d/v1/chat/completions" % PORTS["tlsB"],
            # different HOST NAME, same listener, same port, same key
            "/redirect/cross-host":
                "https://localhost:%d/__leak" % PORTS["tlsA"],
            # different SCHEME (https -> http)
            "/redirect/downgrade":
                "http://127.0.0.1:%d/__leak" % PORTS["plain"],
            # same origin — must be followed
            "/redirect/same-origin":
                "https://127.0.0.1:%d/ok" % PORTS["tlsA"],
            # a converse endpoint under a base path that redirects, so
            # `RemoteAgentClient.send` can be pointed at a redirecting gateway
            "/xredirect/v1/chat/completions":
                "https://127.0.0.1:%d/v1/chat/completions" % PORTS["tlsB"],
        }
        if path in redirects:
            self._send(302, b'{"redirect":true}', {"Location": redirects[path]})
            return

        if path == "/v1/chat/completions":
            body = json.dumps({"choices": [{"message": {
                "role": "assistant",
                "content": "LIVE-REPLY-%s" % self.role}}]}).encode()
            self._send(200, body)
            return

        self._send(200, MARKERS.get(self.role, b"?"))

    def _drain(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)

    def do_GET(self):
        self._route()

    def do_HEAD(self):
        self._route()

    def do_POST(self):
        self._drain()
        self._route()

    def do_PUT(self):
        self._drain()
        self._route()


def serve(role, keypair, workdir):
    server = NoReverseLookupServer(
        ("127.0.0.1", 0), type("Handler_" + role, (Handler,), {"role": role}))
    if keypair is not None:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(os.path.join(workdir, keypair[0]),
                                os.path.join(workdir, keypair[1]))
        server.socket = context.wrap_socket(server.socket, server_side=True)
    PORTS[role] = server.server_address[1]
    return server


def main():
    workdir = sys.argv[1]
    ec = ("ec-cert.pem", "ec-key.pem")
    servers = [
        serve("tlsA", ec, workdir),
        serve("tlsB", ec, workdir),
        serve("tlsRSA", ("rsa-cert.pem", "rsa-key.pem"), workdir),
        serve("plain", None, workdir),
    ]
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()

    tmp = os.path.join(workdir, "ports.json.tmp")
    with open(tmp, "w") as handle:
        json.dump(PORTS, handle)
    os.rename(tmp, os.path.join(workdir, "ports.json"))

    # Teardown: the parent holds the write end of our stdin, so EOF means the
    # runner is gone. Never outlive it. `read(1)`, not `read()` — an unbounded
    # read on a stdin that never EOFs (a terminal, /dev/zero) buffers until the
    # process is killed for memory.
    sys.stdin.read(1)
    os._exit(0)


main()
