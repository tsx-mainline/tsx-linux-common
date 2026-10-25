#!/usr/bin/env python3
"""A fake DevTools endpoint for tests/test-bench.sh.

usage: fake-devtools.py PORT LOGFILE [KIOSK_URL]

It answers GET /json with one page target and one browser UI target, accepts
the WebSocket of the page target and answers the DevTools commands that
tsx-bench-core sends:
  Page.enable        empty result
  Page.navigate      empty result, then the event Page.loadEventFired
  Runtime.evaluate   "tsxBench.run()" gives a JSON text, "location.href" gives
                     the URL of the last navigation
The file LOGFILE gets one line per command: the method and the first 60
characters of the URL. The server splits the first answer in two frames and
sends a ping, so the tests cover fragments and pings.
"""
import base64
import hashlib
import json
import socket
import struct
import sys
import threading

port = int(sys.argv[1])
logf = sys.argv[2]
state = {"url": sys.argv[3] if len(sys.argv) > 3 else "https://kiosk.example/dashboard/0?x=1&y=\"2\""}
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def log(s):
    with open(logf, "a") as f:
        f.write(s + "\n")


def ws_send(c, payload, op=1, fin=True):
    b = payload.encode() if isinstance(payload, str) else payload
    h = bytes([(0x80 if fin else 0) | op])
    if len(b) < 126:
        h += bytes([len(b)])
    elif len(b) < 65536:
        h += bytes([126]) + struct.pack(">H", len(b))
    else:
        h += bytes([127]) + struct.pack(">Q", len(b))
    c.sendall(h + b)


def recv_exact(c, n):
    out = b""
    while len(out) < n:
        d = c.recv(n - len(out))
        if not d:
            raise EOFError
        out += d
    return out


def ws_recv(c):
    h = recv_exact(c, 2)
    ln = h[1] & 127
    if ln == 126:
        ln = struct.unpack(">H", recv_exact(c, 2))[0]
    elif ln == 127:
        ln = struct.unpack(">Q", recv_exact(c, 8))[0]
    mask = recv_exact(c, 4) if h[1] & 128 else b"\0\0\0\0"
    d = recv_exact(c, ln)
    return h[0] & 15, bytes(x ^ mask[i & 3] for i, x in enumerate(d))


def handle(c):
    try:
        req = b""
        while b"\r\n\r\n" not in req:
            d = c.recv(4096)
            if not d:
                return
            req += d
        line = req.split(b"\r\n")[0].decode()
        path = line.split()[1]
        if path == "/json":
            body = json.dumps([
                {"id": "A1", "type": "page", "title": "Kiosk", "url": state["url"],
                 "webSocketDebuggerUrl": "ws://127.0.0.1:%d/devtools/page/A1" % port},
                {"id": "B2", "type": "browser_ui", "title": "UI", "url": "chrome://x/",
                 "webSocketDebuggerUrl": "ws://127.0.0.1:%d/devtools/page/B2" % port},
            ], indent=2).encode()
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
            return
        key = [l.split(":", 1)[1].strip() for l in req.decode().split("\r\n") if l.lower().startswith("sec-websocket-key")][0]
        acc = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        c.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                   "Sec-WebSocket-Accept: %s\r\n\r\n" % acc).encode())
        first = True
        while True:
            op, data = ws_recv(c)
            if op == 8:
                return
            if op in (9, 10):   # ping or pong from the client
                continue
            m = json.loads(data)
            meth, p = m["method"], m.get("params", {})
            if first:
                ws_send(c, b"", op=9)   # a ping before the first answer
            if meth == "Page.navigate":
                state["url"] = p["url"]
                log("navigate " + p["url"][:60])
            elif meth == "Runtime.evaluate":
                log("evaluate " + p["expression"][:30])
            else:
                log(meth)
            if meth == "Runtime.evaluate" and p["expression"].startswith("tsxBench"):
                res = {"type": "string", "value": json.dumps({"schema": 1, "js": {"total_ms": 123.5}, "note": "a \"quoted\" é text"})}
            elif meth == "Runtime.evaluate":
                res = {"type": "string", "value": state["url"]}
            else:
                res = None
            ans = json.dumps({"id": m["id"], "result": ({"result": res} if res else {})}, separators=(",", ":"))
            if first:
                cut = len(ans) // 2     # two frames: a text frame and a continuation
                ws_send(c, ans[:cut], op=1, fin=False)
                ws_send(c, ans[cut:], op=0, fin=True)
                first = False
            else:
                ws_send(c, ans)
            if meth == "Page.navigate":
                ws_send(c, json.dumps({"method": "Page.loadEventFired", "params": {"timestamp": 1}}, separators=(",", ":")))
    except (EOFError, OSError):
        pass
    finally:
        c.close()


s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(8)
while True:
    conn, _ = s.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
