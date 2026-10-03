#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Unit check of the end of a BLE link in btgatt.py, for tests/test-bt.sh.

A peer drops a link, and the ESPHome client connects to the same address
again. tsx-btscan waits DOWN_GRACE for the HCI reason before it sends the
"conn" event. The client takes the first "conn" event after its connect
request as the answer to that connect (aioesphomeapi 46.2). A late "conn"
event of the old link must therefore never reach a client that connects
again. The check runs the real Links class with a fake clock, fake L2CAP
sockets, a fake HCI (the test sends Disconnection Complete itself) and a
fake client. The test picks the order of each step, so the result does not
depend on timing.

  btgatt-race-check.py LIB-DIR

Prints one "ok:" or "FAIL:" line per check. Exit status = the failures.
"""
import collections
import logging
import os
import struct
import sys
import types

os.environ.pop("TSX_BTSCAN_FAKE_L2CAP", None)
sys.path.insert(0, sys.argv[1])
import btgatt  # noqa: E402  pylint: disable=wrong-import-position

A = 0xC0FFEE000001
H_CTRL = 13            # a write of 01 makes the peer drop the link
H_NAME = 3
FAILS = []


def ok(cond, text):
    print(("  ok: " if cond else "  FAIL: ") + text)
    if not cond:
        FAILS.append(text)


class Clock:
    now = 1000.0

    def __call__(self):
        return self.now


CLOCK = Clock()
btgatt.time = types.SimpleNamespace(monotonic=CLOCK)


class FakeSock:
    """The L2CAP socket of one link. recv() with an empty inbox returns b"",
    the way the kernel reports a link that the peer dropped."""

    def __init__(self):
        self.sent = []
        self.inbox = collections.deque()
        self.closed = False

    def send(self, pdu):
        if self.closed:
            raise OSError(107, "Transport endpoint is not connected")
        self.sent.append(bytes(pdu))
        return len(pdu)

    def recv(self, _size):
        return self.inbox.popleft() if self.inbox else b""

    def close(self):
        self.closed = True


class FakeBearer:
    """Replaces L2capBearer. The test brings the link up itself."""

    made = []

    def __init__(self, _addr, _atype):
        self.sock = FakeSock()
        FakeBearer.made.append(self)

    def want_write(self):
        return False

    def poll_up(self, _readable):
        return None


btgatt.L2capBearer = FakeBearer


class FakeClient:
    """One front end with the client rules of aioesphomeapi 46.2 and
    bleak-esphome 4.1 for one address:
      - a connect ends on the first "conn" event after the request
      - a "conn" event with connected=false or an error -1 means "link down"
      - eager=True: the client connects again as soon as it sees the link
        down (the worst case for the proxy)
    Events wait in the inbox (in flight) until the test delivers them.
    Requests wait in the outbox until the test delivers them."""

    def __init__(self, name, eager=False):
        self.name = name
        self.eager = eager
        self.inbox = collections.deque()
        self.outbox = collections.deque()
        self.seen = []           # every event, in the order of arrival
        self.results = []        # the "conn" event that ended each connect
        self.waiting = False

    def connect(self):
        self.outbox.append({"op": "connect", "addr": A, "atype": 1})
        self.waiting = True

    def receive(self):
        while self.inbox:
            msg = self.inbox.popleft()
            self.seen.append(msg)
            if msg.get("ev") == "conn" and self.waiting:
                self.waiting = False
                self.results.append(msg)
                continue
            down = (msg.get("ev") == "conn" and not msg["connected"]) or \
                (msg.get("ev") == "error" and msg["error"] == -1)
            if down and self.eager and not self.waiting:
                self.connect()


class Rig:
    def __init__(self):
        self.hci = []
        self.links = btgatt.Links(3, self.emit, lambda: None, lambda: None, lambda: None,
                                  lambda op, params: self.hci.append((op, bytes(params))), lambda: None)
        self.handles = iter(range(0x40, 0x80))

    @staticmethod
    def emit(client, msg):
        client.inbox.append(dict(msg))

    def deliver(self, client):
        while client.outbox:
            self.links.request(client, client.outbox.popleft())

    def link(self):
        return self.links.links.get(A)

    def bring_up(self, client):
        """Start the queued link, the peer accepts, the MTU exchange runs."""
        self.links.tick(CLOCK())
        link = self.link()
        assert link is not None and link.state == "connecting", link and link.state
        handle = next(self.handles)
        self.links.link_up(link, handle, CLOCK())
        sock = link.bearer.sock
        assert sock.sent[-1][:1] == b"\x02", sock.sent
        sock.inbox.append(b"\x03" + struct.pack("<H", 185))
        self.links.on_readable(sock, CLOCK())
        client.receive()
        return link

    def drop(self, link):
        """The peer drops the link: the socket reports it, no HCI event yet."""
        self.links.on_readable(link.bearer.sock, CLOCK())

    def grace(self):
        CLOCK.now += btgatt.DOWN_GRACE + 0.01
        self.links.tick(CLOCK())


def connected(msg):
    return msg is not None and msg.get("ev") == "conn" and msg["connected"]


def no_minus_one(client):
    return not any(m.get("ev") == "error" and m["error"] == -1 for m in client.seen)


def first_conn(client):
    return next((m for m in client.seen if m.get("ev") == "conn"), None)


def case_late_event():
    """A drop while a write waits. The proxy sends the "conn" event after
    DOWN_GRACE, and only then reads the connect of the client (the worst
    order of the race)."""
    rig = Rig()
    cli = FakeClient("ha", eager=True)
    cli.connect()
    rig.deliver(cli)
    link = rig.bring_up(cli)
    ok(connected(cli.results[-1] if cli.results else None), "late event: the first connect succeeds")
    cli.seen.clear()
    cli.outbox.append({"op": "write", "addr": A, "handle": H_CTRL, "data": "01", "response": True})
    rig.deliver(cli)
    rig.drop(link)
    cli.receive()       # whatever the proxy sent at the drop arrives now
    rig.grace()         # the proxy sends the "conn" event of the old link
    rig.deliver(cli)    # a connect that the client sent before that event
    cli.receive()
    rig.deliver(cli)    # a connect that the client sent after that event
    if rig.link() is not None and rig.link().state == "queued":
        rig.bring_up(cli)
    cli.receive()
    first = first_conn(cli)
    ok(no_minus_one(cli), "late event: the drop sends no error -1 for the waiting write")
    ok(first is not None and not first["connected"] and first["error"] == btgatt.CONN_REMOTE,
       f"late event: the first message about the drop is the conn event, reason 0x13: {first}")
    ok(len(cli.results) == 2 and connected(cli.results[1]),
       f"late event: the reconnect gets connected=true, not the old conn event: {cli.results[1:]}")
    ok(rig.link() is not None and rig.link().state == "connected", "late event: the new link is up")


def case_connect_in_grace():
    """The client connects while the old link waits for its HCI reason."""
    rig = Rig()
    cli = FakeClient("ha")
    cli.connect()
    rig.deliver(cli)
    link = rig.bring_up(cli)
    cli.seen.clear()
    rig.drop(link)
    cli.receive()
    cli.connect()
    rig.deliver(cli)    # the connect arrives inside DOWN_GRACE
    rig.grace()
    cli.receive()
    ok(not cli.seen, f"connect in the grace time: the stale conn event of the old link is dropped: {cli.seen}")
    rig.bring_up(cli)
    ok(len(cli.results) == 2 and connected(cli.results[1]),
       f"connect in the grace time: the next conn event is connected=true: {cli.results[1:]}")


def case_other_owner():
    """Front end B connects while the link of front end A goes down."""
    rig = Rig()
    cli_a, cli_b = FakeClient("a"), FakeClient("b")
    cli_a.connect()
    rig.deliver(cli_a)
    link = rig.bring_up(cli_a)
    cli_a.seen.clear()
    rig.drop(link)
    cli_b.connect()
    rig.deliver(cli_b)
    rig.grace()
    cli_a.receive()
    cli_b.receive()
    ok(len(cli_a.seen) == 1 and not cli_a.seen[0]["connected"] and cli_a.seen[0]["error"] == btgatt.CONN_REMOTE,
       f"another front end: the old owner still gets its conn event: {cli_a.seen}")
    ok(not cli_b.results, "another front end: the new client gets no conn event of the old link")
    rig.bring_up(cli_b)
    ok(len(cli_b.results) == 1 and connected(cli_b.results[0]), "another front end: its connect succeeds")


def case_hci_reason():
    """The HCI reason arrives inside DOWN_GRACE. A read that the client
    sends in that time gets no error -1: the conn event answers it."""
    rig = Rig()
    cli = FakeClient("ha")
    cli.connect()
    rig.deliver(cli)
    link = rig.bring_up(cli)
    cli.seen.clear()
    rig.drop(link)
    cli.outbox.append({"op": "read", "addr": A, "handle": H_NAME})
    rig.deliver(cli)
    cli.receive()
    ok(not cli.seen, f"HCI reason: nothing reaches the client before the HCI event: {cli.seen}")
    CLOCK.now += btgatt.DOWN_GRACE / 2
    rig.links.on_disconnect(link.handle, btgatt.CONN_TIMEOUT)
    cli.receive()
    ok(cli.seen == [{"ev": "conn", "addr": A, "connected": False, "mtu": 0, "error": btgatt.CONN_TIMEOUT}],
       f"HCI reason: one conn event with the HCI reason 0x08, no error -1: {cli.seen}")
    rig.grace()
    cli.receive()
    ok(len(cli.seen) == 1, "HCI reason: no second conn event after DOWN_GRACE")


def case_requested():
    """The client disconnects while a read waits. The proxy sends HCI
    Disconnect and one conn event with the HCI reason, no error -1."""
    rig = Rig()
    cli = FakeClient("ha")
    cli.connect()
    rig.deliver(cli)
    link = rig.bring_up(cli)
    cli.seen.clear()
    cli.outbox.append({"op": "read", "addr": A, "handle": H_NAME})
    cli.outbox.append({"op": "disconnect", "addr": A})
    rig.deliver(cli)
    cli.receive()
    ok(rig.hci and rig.hci[-1] == (0x0406, struct.pack("<HB", link.handle, btgatt.CONN_REMOTE)) and not cli.seen,
       f"disconnect: HCI Disconnect and no answer before the HCI event: {cli.seen}")
    rig.links.on_disconnect(link.handle, btgatt.CONN_LOCAL)
    cli.receive()
    ok(cli.seen == [{"ev": "conn", "addr": A, "connected": False, "mtu": 0, "error": btgatt.CONN_LOCAL}],
       f"disconnect: one conn event with reason 0x16, no error -1: {cli.seen}")
    cli.outbox.append({"op": "read", "addr": A, "handle": H_NAME})
    rig.deliver(cli)
    cli.receive()
    ok(cli.seen[-1] == {"ev": "error", "addr": A, "handle": H_NAME, "error": -1},
       "disconnect: a request after the conn event gets error -1")


def main():
    logging.disable(logging.CRITICAL)
    case_late_event()
    case_connect_in_grace()
    case_other_owner()
    case_hci_reason()
    case_requested()
    return len(FAILS)


if __name__ == "__main__":
    sys.exit(main())
