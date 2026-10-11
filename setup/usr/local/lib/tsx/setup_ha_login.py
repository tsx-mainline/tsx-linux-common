"""The Home Assistant side of "Log in with Home Assistant" on the setup page
(tsx-setupd, docs/setup.md "Log in with Home Assistant").

tsx-setupd sends the browser to the login page of Home Assistant (the
OAuth 2 / IndieAuth flow of Home Assistant, <HA>/auth/authorize). Home
Assistant sends the browser back to the setup page with a code. This module
then does the three steps on the panel, with the Python standard library
only:

  exchange_code   POST <HA>/auth/token (grant_type=authorization_code): the
                  code and the client_id give an access token and a refresh
                  token.
  current_user    the websocket API of Home Assistant (<HA>/api/websocket):
                  auth with the access token, then auth/current_user. It
                  gives the name, the id and is_admin of the user.
  revoke          POST <HA>/auth/revoke with the refresh token. Home
                  Assistant then removes the refresh token and the access
                  tokens that it made. The panel keeps no token.

The module never logs a token, and its errors never contain one. A redirect
of Home Assistant is refused: the requests go only to the configured URL.

Env for host tests: none. The tests use a fake Home Assistant on http.
"""
import base64
import hashlib
import json
import os
import socket
import ssl
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT = 10.0
MAX_BODY = 65536
MAX_WS_MESSAGE = 1048576
_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class HaError(Exception):
    """A step of the login failed. The text is safe to show and to log."""


def normalize_ha_url(text):
    """The origin of an http(s) URL ("https://ha.example.org:8443"), or None.
    A URL with a user name or a password gives None. The path is dropped."""
    if not isinstance(text, str):
        return None
    text = text.strip()
    try:
        u = urllib.parse.urlsplit(text)
        port = u.port
    except ValueError:
        return None
    if u.scheme not in ("http", "https") or not u.hostname or u.username or u.password:
        return None
    if any(c in u.netloc for c in " \t\r\n\"'<>\\"):
        return None
    host = u.hostname
    if ":" in host:
        host = "[%s]" % host
    return "%s://%s%s" % (u.scheme, host, ":%d" % port if port else "")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "redirect refused", headers, fp)


_OPENER = urllib.request.build_opener(_NoRedirect)


def _post_form(url, fields, timeout):
    data = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(url, data=data, method="POST", headers={
        "Content-Type": "application/x-www-form-urlencoded", "User-Agent": "tsx-setupd"})
    try:
        with _OPENER.open(req, timeout=timeout) as resp:
            return resp.status, resp.read(MAX_BODY)
    except urllib.error.HTTPError as e:
        try:
            body = e.read(MAX_BODY) if e.fp is not None else b""
        except OSError:
            body = b""
        return e.code, body
    except ssl.SSLError as e:
        raise HaError("TLS error with Home Assistant: %s" % (getattr(e, "reason", None) or "the handshake failed"))
    except (urllib.error.URLError, OSError) as e:
        reason = getattr(e, "reason", e)
        raise HaError("Home Assistant is not reachable from the panel: %s" % str(reason)[:120])


def exchange_code(ha, code, client_id, timeout=TIMEOUT):
    """The tokens for an authorization code: {"access_token", "refresh_token"
    (can be missing), "expires_in"}. Raises HaError."""
    status, body = _post_form(ha + "/auth/token", {
        "grant_type": "authorization_code", "code": code, "client_id": client_id}, timeout)
    if status != 200:
        raise HaError("Home Assistant refused the login code (HTTP %d)" % status)
    try:
        data = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise HaError("Home Assistant sent an answer that is not JSON")
    if not isinstance(data, dict) or not isinstance(data.get("access_token"), str) or not data["access_token"]:
        raise HaError("Home Assistant sent no access token")
    return data


def revoke(ha, refresh_token, timeout=TIMEOUT):
    """Remove the refresh token (and its access tokens) in Home Assistant.
    True when Home Assistant accepted the request. It never raises."""
    if not refresh_token:
        return False
    try:
        status, _ = _post_form(ha + "/auth/revoke", {"token": refresh_token}, timeout)
        if status in (404, 405):
            # Home Assistant before /auth/revoke: the old form of /auth/token
            status, _ = _post_form(ha + "/auth/token", {"action": "revoke", "token": refresh_token}, timeout)
        return status == 200
    except HaError:
        return False


# ---- a small websocket client (RFC 6455): text frames, one request ----------

class _Ws:
    def __init__(self, ha, timeout):
        u = urllib.parse.urlsplit(ha)
        self.host = u.hostname
        port = u.port or (443 if u.scheme == "https" else 80)
        try:
            sock = socket.create_connection((self.host, port), timeout=timeout)
        except OSError as e:
            raise HaError("Home Assistant is not reachable from the panel: %s" % str(e)[:120])
        if u.scheme == "https":
            try:
                sock = ssl.create_default_context().wrap_socket(sock, server_hostname=self.host)
            except (ssl.SSLError, OSError) as e:
                sock.close()
                raise HaError("TLS error with Home Assistant: %s" % str(e)[:120])
        sock.settimeout(timeout)
        self.sock = sock
        self.buf = b""
        key = base64.b64encode(os.urandom(16)).decode()
        req = ("GET /api/websocket HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nUser-Agent: tsx-setupd\r\n\r\n"
               % (u.netloc, key))
        self._send_raw(req.encode())
        head = self._read_until(b"\r\n\r\n", 16384)
        lines = head.decode("latin-1").split("\r\n")
        if not lines or len(lines[0].split()) < 2 or lines[0].split()[1] != "101":
            raise HaError("the websocket API of Home Assistant refused the connection")
        want = base64.b64encode(hashlib.sha1((key + _WS_GUID).encode()).digest()).decode()
        accept = ""
        for line in lines[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                if k.strip().lower() == "sec-websocket-accept":
                    accept = v.strip()
        if accept != want:
            raise HaError("the websocket API of Home Assistant sent a wrong handshake")

    def _send_raw(self, data):
        try:
            self.sock.sendall(data)
        except OSError as e:
            raise HaError("the connection to Home Assistant broke: %s" % str(e)[:120])

    def _recv(self, n):
        while len(self.buf) < n:
            try:
                chunk = self.sock.recv(65536)
            except OSError as e:
                raise HaError("the connection to Home Assistant broke: %s" % str(e)[:120])
            if not chunk:
                raise HaError("Home Assistant closed the websocket")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _read_until(self, mark, cap):
        while mark not in self.buf:
            if len(self.buf) > cap:
                raise HaError("the answer of Home Assistant is too long")
            try:
                chunk = self.sock.recv(4096)
            except OSError as e:
                raise HaError("the connection to Home Assistant broke: %s" % str(e)[:120])
            if not chunk:
                raise HaError("Home Assistant closed the connection")
            self.buf += chunk
        i = self.buf.index(mark) + len(mark)
        out, self.buf = self.buf[:i], self.buf[i:]
        return out

    def _frame(self, opcode, payload):
        mask = os.urandom(4)
        n = len(payload)
        if n < 126:
            head = bytes([0x80 | opcode, 0x80 | n])
        elif n < 65536:
            head = bytes([0x80 | opcode, 0x80 | 126]) + n.to_bytes(2, "big")
        else:
            head = bytes([0x80 | opcode, 0x80 | 127]) + n.to_bytes(8, "big")
        body = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self._send_raw(head + mask + body)

    def send_json(self, obj):
        self._frame(0x1, json.dumps(obj).encode())

    def recv_json(self):
        data = b""
        while True:
            b0, b1 = self._recv(2)
            fin, opcode = b0 & 0x80, b0 & 0x0F
            n = b1 & 0x7F
            if n == 126:
                n = int.from_bytes(self._recv(2), "big")
            elif n == 127:
                n = int.from_bytes(self._recv(8), "big")
            if n > MAX_WS_MESSAGE or len(data) + n > MAX_WS_MESSAGE:
                raise HaError("a websocket message of Home Assistant is too long")
            mask = self._recv(4) if b1 & 0x80 else None
            payload = self._recv(n)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x8:
                raise HaError("Home Assistant closed the websocket")
            if opcode == 0x9:
                self._frame(0xA, payload)
                continue
            if opcode == 0xA:
                continue
            if opcode in (0x0, 0x1):
                data += payload
                if fin:
                    try:
                        return json.loads(data.decode("utf-8"))
                    except (UnicodeDecodeError, ValueError):
                        raise HaError("Home Assistant sent a websocket message that is not JSON")
                continue
            raise HaError("Home Assistant sent an unexpected websocket frame")

    def close(self):
        try:
            self._frame(0x8, b"\x03\xe8")
        except HaError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


def current_user(ha, access_token, timeout=TIMEOUT):
    """{"id", "name", "is_admin", "is_owner"} of the user of the access token,
    from the websocket API. Raises HaError."""
    ws = _Ws(ha, timeout)
    try:
        msg = ws.recv_json()
        if not isinstance(msg, dict) or msg.get("type") != "auth_required":
            raise HaError("the websocket API of Home Assistant did not ask for the login")
        ws.send_json({"type": "auth", "access_token": access_token})
        msg = ws.recv_json()
        if not isinstance(msg, dict) or msg.get("type") != "auth_ok":
            raise HaError("Home Assistant did not accept the access token")
        ws.send_json({"id": 1, "type": "auth/current_user"})
        for _ in range(20):
            msg = ws.recv_json()
            if isinstance(msg, dict) and msg.get("id") == 1:
                break
        else:
            raise HaError("Home Assistant did not answer auth/current_user")
        if msg.get("type") != "result" or not msg.get("success") or not isinstance(msg.get("result"), dict):
            raise HaError("Home Assistant refused auth/current_user")
        r = msg["result"]
        return {"id": str(r.get("id") or ""), "name": str(r.get("name") or "")[:100],
                "is_admin": r.get("is_admin") is True, "is_owner": r.get("is_owner") is True}
    finally:
        ws.close()
