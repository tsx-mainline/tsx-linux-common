#!/usr/bin/env python3
"""A fake Home Assistant for tests/test-setup-login.sh: the parts of the auth
API that "Log in with Home Assistant" of the setup page uses.

  fake-ha.py PORT LOG

  GET  /auth/authorize   the login page of Home Assistant. A real one shows a
                         form. This one logs in the user of the extra query
                         parameter "user" (admin or guest) at once and sends
                         the browser back: 302 to redirect_uri?code=..&state=..
                         It checks the IndieAuth rule of Home Assistant: the
                         redirect_uri has the scheme and the host of the
                         client_id. "deny=1" sends error=access_denied.
  POST /auth/token       grant_type=authorization_code: the code (one use, the
                         same client_id) gives an access token and a refresh
                         token. action=revoke: the old revoke.
  POST /auth/revoke      token=REFRESH: removes the refresh token and its
                         access token.
  GET  /api/websocket    the websocket API: auth_required, auth with the
                         access token, then auth/current_user.

Each event goes to LOG as one JSON line ({"event": ...}). The log never has a
token, only the event and the user.
"""
import base64
import hashlib
import json
import secrets
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

USERS = {"admin": {"id": "u-admin", "name": "Admin", "is_admin": True, "is_owner": True},
         "guest": {"id": "u-guest", "name": "Guest", "is_admin": False, "is_owner": False}}
LOCK = threading.Lock()
CODES = {}      # code -> (user, client_id)
REFRESH = {}    # refresh token -> access token
ACCESS = {}     # access token -> user
LOG = None


def log(event, **kw):
    with LOCK, open(LOG, "a") as f:
        f.write(json.dumps(dict(event=event, **kw)) + "\n")


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _reply(self, code, obj=None, headers=None):
        body = json.dumps(obj).encode() if obj is not None else b""
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _form(self):
        n = int(self.headers.get("Content-Length") or 0)
        return {k: v[0] for k, v in urllib.parse.parse_qs(self.rfile.read(n).decode()).items()}

    def do_GET(self):
        u = urllib.parse.urlsplit(self.path)
        q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
        if u.path == "/auth/authorize":
            cid, ruri = q.get("client_id", ""), q.get("redirect_uri", "")
            a, b = urllib.parse.urlsplit(cid), urllib.parse.urlsplit(ruri)
            if q.get("response_type") != "code" or (a.scheme, a.netloc) != (b.scheme, b.netloc) or not a.path:
                log("authorize-refused", client_id=cid)
                self._reply(400, {"error": "invalid redirect_uri"})
                return
            sep = "&" if "?" in ruri else "?"
            if q.get("deny"):
                loc = ruri + sep + urllib.parse.urlencode({"error": "access_denied", "state": q.get("state", "")})
            else:
                user = q.get("user", "admin")
                code = secrets.token_hex(16)
                with LOCK:
                    CODES[code] = (user, cid)
                log("authorize", user=user, client_id=cid)
                loc = ruri + sep + urllib.parse.urlencode({"code": code, "state": q.get("state", "")})
            self._reply(302, None, {"Location": loc})
            return
        if u.path == "/api/websocket":
            self._websocket()
            return
        self._reply(404, {"error": "not found"})

    def do_POST(self):
        u = urllib.parse.urlsplit(self.path)
        f = self._form()
        if u.path == "/auth/token" and f.get("grant_type") == "authorization_code":
            with LOCK:
                rec = CODES.pop(f.get("code", ""), None)
            if rec is None or rec[1] != f.get("client_id"):
                log("token-refused")
                self._reply(400, {"error": "invalid_request"})
                return
            at, rt = "AT" + secrets.token_hex(16), "RT" + secrets.token_hex(16)
            with LOCK:
                ACCESS[at] = rec[0]
                REFRESH[rt] = at
            log("token", user=rec[0])
            self._reply(200, {"access_token": at, "refresh_token": rt, "expires_in": 1800, "token_type": "Bearer"})
            return
        if u.path == "/auth/revoke" or (u.path == "/auth/token" and f.get("action") == "revoke"):
            with LOCK:
                at = REFRESH.pop(f.get("token", ""), None)
                user = ACCESS.pop(at, None) if at else None
            log("revoke", user=user, known=at is not None)
            self._reply(200, {})
            return
        self._reply(404, {"error": "not found"})

    # ---- a small websocket server (text frames) ----
    def _websocket(self):
        key = self.headers.get("Sec-WebSocket-Key", "")
        acc = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", acc)
        self.end_headers()
        self.wfile.flush()
        sock = self.connection

        def send(obj):
            p = json.dumps(obj).encode()
            # two frames: a fragmented message, as a test of the client
            half = len(p) // 2
            sock.sendall(bytes([0x01, half]) + p[:half] if half < 126 else bytes([0x01, 126]) + half.to_bytes(2, "big") + p[:half])
            rest = p[half:]
            n = len(rest)
            sock.sendall((bytes([0x80, n]) if n < 126 else bytes([0x80, 126]) + n.to_bytes(2, "big")) + rest)

        def recv_exact(n):
            b = b""
            while len(b) < n:
                c = sock.recv(n - len(b))
                if not c:
                    raise EOFError
                b += c
            return b

        def recv():
            while True:
                b0, b1 = recv_exact(2)
                n = b1 & 0x7F
                if n == 126:
                    n = int.from_bytes(recv_exact(2), "big")
                elif n == 127:
                    n = int.from_bytes(recv_exact(8), "big")
                if not b1 & 0x80:
                    raise ValueError("a client frame must be masked")
                mask = recv_exact(4)
                p = bytes(x ^ mask[i % 4] for i, x in enumerate(recv_exact(n)))
                if b0 & 0x0F == 0x8:
                    raise EOFError
                if b0 & 0x0F == 0xA:
                    log("ws-pong", ok=p == b"hi")
                    continue
                return json.loads(p.decode())

        try:
            sock.sendall(bytes([0x89, 2]) + b"hi")   # a ping first: the client answers it
            send({"type": "auth_required", "ha_version": "2026.9.0"})
            msg = recv()
            user = ACCESS.get(msg.get("access_token", "")) if msg.get("type") == "auth" else None
            if user is None:
                send({"type": "auth_invalid", "message": "Invalid access token"})
                log("ws-auth-invalid")
                return
            send({"type": "auth_ok", "ha_version": "2026.9.0"})
            msg = recv()
            if msg.get("type") == "auth/current_user":
                send({"id": msg.get("id"), "type": "result", "success": True, "result": dict(USERS[user], credentials=[])})
                log("current_user", user=user)
        except (EOFError, OSError, ValueError):
            pass


def main():
    global LOG
    LOG = sys.argv[2]
    srv = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H)
    print("fake-ha listening", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
