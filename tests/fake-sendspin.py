#!/usr/bin/env python3
"""A fake Sendspin player for tests/test-volume-sendspin.sh.

  fake-sendspin.py serve SOCKET VOLUME_FILE VOLUME MUTED
      The player: a control socket and the volume file, as sendspin-cli
      0.3.0-r1 with --control-socket and --volume-file. One request line per
      connection, the reply "ok" or "error <kind>: <reason>". It takes
      player-vol N, player-mute on|off and status, and two lines that only a
      test sends: server-vol N and server-mute on|off (a change that Music
      Assistant makes). Each change writes the volume file (atomically, mode
      0644). Every request line goes to SOCKET.log. "quit" stops it.

  fake-sendspin.py SUBCOMMAND [ARG] --control-socket SOCKET
      The client, as "sendspin-cli SUBCOMMAND ARG --control-socket SOCKET":
      exit 0 for "ok", 2 for an error reply, 3 when nothing listens.
"""
import os
import socket
import sys


def write_volume(path, volume, muted):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as f:
        f.write("# Written by sendspin-cli. Edits are overwritten.\n")
        f.write("volume = %d\nmuted = %s\n" % (volume, "true" if muted else "false"))
    os.chmod(tmp, 0o644)
    os.rename(tmp, path)


def serve(sock_path, vol_path, volume, muted):
    if os.path.exists(sock_path):
        os.unlink(sock_path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    srv.listen(8)
    write_volume(vol_path, volume, muted)
    log = open(sock_path + ".log", "a", buffering=1)
    while True:
        conn, _ = srv.accept()
        with conn:
            data = b""
            while b"\n" not in data:
                chunk = conn.recv(256)
                if not chunk:
                    break
                data += chunk
            words = data.decode("utf-8", "replace").strip().split()
            log.write(" ".join(words) + "\n")
            reply = "ok\n"
            cmd, arg = (words + ["", ""])[:2]
            if cmd in ("player-vol", "server-vol") and arg.isdigit() and int(arg) <= 100 and len(words) == 2:
                volume = int(arg)
            elif cmd in ("player-mute", "server-mute") and arg in ("on", "off") and len(words) == 2:
                muted = arg == "on"
            elif cmd == "status" and len(words) == 1:
                reply = "ok\nplayer volume: %d%s\n" % (volume, " (muted)" if muted else "")
            elif cmd == "quit":
                conn.sendall(reply.encode())
                break
            else:
                reply = "error usage: bad request\n"
            if reply.startswith("ok") and cmd != "status":
                write_volume(vol_path, volume, muted)
            conn.sendall(reply.encode())
    srv.close()
    os.unlink(sock_path)


def client(argv):
    if "--control-socket" not in argv:
        return 1
    i = argv.index("--control-socket")
    sock_path = argv[i + 1]
    words = argv[:i] + argv[i + 2:]
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(sock_path)
    except OSError:
        print("error: nothing is listening on %s" % sock_path, file=sys.stderr)
        return 3
    s.sendall((" ".join(words) + "\n").encode())
    reply = b""
    while True:
        chunk = s.recv(256)
        if not chunk:
            break
        reply += chunk
    s.close()
    text = reply.decode()
    sys.stdout.write(text.split("\n", 1)[1] if "\n" in text else "")
    return 0 if text.startswith("ok") else 2


if __name__ == "__main__":
    if len(sys.argv) == 6 and sys.argv[1] == "serve":
        serve(sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5] == "true")
        sys.exit(0)
    sys.exit(client(sys.argv[1:]))
