#!/usr/bin/env python3
"""The mDNS announcement of the ESPHome API (ha/voice/shim/tsx_panel/mdns.py,
docs/esphome.md "Network address and mDNS"), for tests/test-esphome.sh.

A fake route file (TSX_ROUTE_FILE) and a fake netifaces give the default
route and the interface addresses, and a fake AsyncZeroconf keeps the
service records. The records are the real zeroconf AsyncServiceInfo of
linux-voice-assistant. Nothing goes to the network. Cases:
  - no default route at start (no DHCP lease): no record, then a lease: the
    record holds the address
  - the same address: the record stays. A new address: a new record. The
    address goes away: the record goes, and it comes back with the address
  - an interface with 0.0.0.0 only: no record. Two addresses: both
  - the default route goes away: the interface of the last route counts
  - a failed read of the addresses keeps the record
  - a fixed address (--host): only that one. --host 0.0.0.0: the interface
  - a failed announcement is tried again at the next poll
  - the background poll follows a change by itself
  - the record carries the TXT of security.py (api_encryption)
  - the voice satellite (tsx_lva._patch_listen): LVA listens on 0.0.0.0 and
    announces with tsx_panel.mdns.Announcer, with the --network-interface.
    The __main__.py of the pinned LVA still reads both names as globals of
    its module at run time (an ast check), so the patch takes effect

  PYTHONPATH=ha/voice/shim:<linux-voice-assistant source> esphome-mdns-check.py
"""
import ast
import asyncio
import atexit
import logging
import os
import shutil
import sys
import tempfile
import types

FAILS = []


def check(cond, text):
    print(("OK: " if cond else "FAIL: ") + text, flush=True)
    if not cond:
        FAILS.append(text)


# ---- NET holds the default route and the addresses of the "host" ----------
AF_INET = 2
TMP = tempfile.mkdtemp(prefix="tsx-mdns-check-")
atexit.register(shutil.rmtree, TMP, True)
ROUTE_FILE = os.path.join(TMP, "route")
os.environ["TSX_ROUTE_FILE"] = ROUTE_FILE
HEADER = "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n"


def write_routes(lines):
    with open(ROUTE_FILE, "w", encoding="ascii") as fobj:
        fobj.write(HEADER + "".join(line + "\n" for line in lines))


class Net(dict):
    """gateway: (router, interface) or None. Every update writes the route file
    the way the kernel shows it (a default route and the subnet route)."""

    def update(self, *args, **kwargs):
        super().update(*args, **kwargs)
        gw = self.get("gateway")
        write_routes([f"{gw[1]}\t00000000\t0100000A\t0003\t0\t0\t10\t00000000\t0\t0\t0",
                      f"{gw[1]}\t0000000A\t00000000\t0001\t0\t0\t10\t00FFFFFF\t0\t0\t0"] if gw else [])


NET = Net()
NET.update(gateway=None, addrs={})


def _fake_netifaces():
    mod = types.ModuleType("netifaces")
    mod.AF_INET = AF_INET

    def ifaddresses(iface):
        if iface not in NET["addrs"]:
            return {}
        return {AF_INET: [{"addr": a, "mask": "255.255.255.0"} for a in NET["addrs"][iface]], 17: [{"addr": "02:00:00:00:00:01"}]}

    mod.ifaddresses = ifaddresses
    return mod


sys.modules["netifaces"] = _fake_netifaces()


class FakeZeroconf:
    """Stands in for AsyncZeroconf: keeps the registered records."""
    made = []
    fail_next = 0

    def __init__(self):
        self.infos, self.closed = [], False
        FakeZeroconf.made.append(self)

    async def async_register_service(self, info):
        if FakeZeroconf.fail_next:
            FakeZeroconf.fail_next -= 1
            raise OSError("fake: no route to the network")
        self.infos.append(info)

    async def async_close(self):
        self.closed = True


def live():
    """The instances that are not closed, and the addresses of their records."""
    zcs = [z for z in FakeZeroconf.made if not z.closed]
    return zcs, [i.parsed_addresses() for z in zcs for i in z.infos]


def lva_main_reads_globals(path):
    """True when __main__.py of LVA imports get_default_ipv4 and
    HomeAssistantZeroconf at module level and main() loads them as globals."""
    tree = ast.parse(open(path, encoding="utf-8").read())
    names = {"get_default_ipv4", "HomeAssistantZeroconf"}
    imported = {a.asname or a.name for n in tree.body if isinstance(n, ast.ImportFrom) for a in n.names}
    main_fn = [n for n in tree.body if isinstance(n, ast.AsyncFunctionDef) and n.name == "main"]
    if not main_fn or not names <= imported:
        return False
    local = {a.arg for a in main_fn[0].args.args}
    for node in ast.walk(main_fn[0]):
        if isinstance(node, (ast.Import, ast.ImportFrom)) and names & {a.asname or a.name for a in node.names}:
            return False
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Store) and node.id in names:
            local.add(node.id)
    used = {n.id for n in ast.walk(main_fn[0]) if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Load)}
    return names <= used and not names & local


async def main():
    from tsx_panel import mdns  # noqa: WPS433

    # ---- the route file: the default route with the lowest metric --------
    write_routes(["eth0\t0000000A\t00000000\t0001\t0\t0\t0\t00FFFFFF\t0\t0\t0"])
    check(mdns.default_interface() is None, "route file: a subnet route only: no default route")
    write_routes(["wlan0\t00000000\t0107A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0",
                  "usb0\t00000000\t0102A8C0\t0002\t0\t0\t0\t00000000\t0\t0\t0",
                  "eth0\t00000000\t0100000A\t0003\t0\t0\t100\t00000000\t0\t0\t0"])
    check(mdns.default_interface() == "eth0", "route file: the lowest metric of the default routes that are up (eth0)")

    def new(**kwargs):
        return mdns.Announcer(port=6053, mac_address="02:00:00:00:00:01", name="tsx-test",
                              zeroconf=FakeZeroconf, **kwargs)

    # ---- no lease at start, then a lease -------------------------------
    NET.update(gateway=None, addrs={"eth0": []})
    ann = new(host_ip_address="0.0.0.0")   # tsx-esphome without --host passes None. LVA passes 0.0.0.0
    await ann.refresh()
    check(not FakeZeroconf.made and ann.announced == [], "no default route (no lease): nothing announced")
    NET.update(gateway=("10.0.0.1", "eth0"))
    await ann.refresh()
    check(not FakeZeroconf.made, "a route but no address yet: nothing announced")
    NET["addrs"]["eth0"] = ["10.0.0.24"]
    await ann.refresh()
    zcs, recs = live()
    check(len(zcs) == 1 and recs == [["10.0.0.24"]] and ann.announced == ["10.0.0.24"],
          f"the lease: the record holds 10.0.0.24 ({recs})")
    info = zcs[0].infos[0]
    check(info.name == "tsx-test._esphomelib._tcp.local." and info.server == "tsx-test.local." and info.port == 6053,
          f"the record: name, host name and port ({info.name}, {info.server}, {info.port})")
    check(info.properties.get(b"mac") == b"02:00:00:00:00:01" and info.properties.get(b"platform") == b"HOST",
          "the record: the TXT of linux-voice-assistant with the MAC address")

    # ---- the same address, a new address, no address, back -------------
    await ann.refresh()
    check(len(FakeZeroconf.made) == 1 and not FakeZeroconf.made[0].closed, "the same address: the record stays")
    NET["addrs"]["eth0"] = ["10.0.2.24"]
    await ann.refresh()
    zcs, recs = live()
    check(FakeZeroconf.made[0].closed and recs == [["10.0.2.24"]] and ann.announced == ["10.0.2.24"],
          f"a new address: the old record is withdrawn, the new one holds 10.0.2.24 ({recs})")
    NET["addrs"]["eth0"] = []
    await ann.refresh()
    zcs, recs = live()
    check(not zcs and ann.announced == [], "the address goes away: no record")
    NET["addrs"]["eth0"] = ["0.0.0.0"]
    await ann.refresh()
    check(not live()[0], "an interface with 0.0.0.0 only: no record (never 0.0.0.0)")
    NET["addrs"]["eth0"] = ["10.0.2.24", "0.0.0.0", "192.168.7.2"]
    await ann.refresh()
    zcs, recs = live()
    check(recs == [["10.0.2.24", "192.168.7.2"]], f"two addresses: both in the record, not 0.0.0.0 ({recs})")
    NET.update(gateway=("192.168.7.1", "wlan0"), addrs={"eth0": [], "wlan0": ["192.168.7.9"]})
    await ann.refresh()
    zcs, recs = live()
    check(recs == [["192.168.7.9"]], f"the default route moves to another interface: its address ({recs})")
    NET.update(gateway=None)
    NET["addrs"]["wlan0"] = ["192.168.7.9"]
    await ann.refresh()
    check(live()[1] == [["192.168.7.9"]], "the default route goes away: the record of its interface stays")
    NET["addrs"]["wlan0"] = ["192.168.7.11"]
    await ann.refresh()
    check(live()[1] == [["192.168.7.11"]], "no default route: a new address of the last interface replaces the record")
    os.environ["TSX_ROUTE_FILE"] = ROUTE_FILE + ".missing"
    made = len(FakeZeroconf.made)
    logging.disable(logging.WARNING)
    await ann.refresh()
    logging.disable(logging.NOTSET)
    os.environ["TSX_ROUTE_FILE"] = ROUTE_FILE
    check(live()[1] == [["192.168.7.11"]] and len(FakeZeroconf.made) == made,
          "a failed read of the addresses: the record stays as it is")
    await ann.close()
    check(not live()[0], "close(): the record is withdrawn")

    # ---- a fixed interface, a fixed address ----------------------------
    FakeZeroconf.made.clear()
    NET.update(gateway=("192.168.7.1", "wlan0"), addrs={"eth0": ["10.0.0.5"], "wlan0": ["192.168.7.9"]})
    ann = new(interface="eth0")
    await ann.refresh()
    check(live()[1] == [["10.0.0.5"]], "--network-interface eth0: the address of eth0, not of the default route")
    await ann.close()
    FakeZeroconf.made.clear()
    ann = new(host_ip_address="10.9.8.7")
    await ann.refresh()
    NET["addrs"]["wlan0"] = ["192.168.7.10"]
    await ann.refresh()
    check(live()[1] == [["10.9.8.7"]] and len(FakeZeroconf.made) == 1, "--host 10.9.8.7: only that address, it does not follow the interface")
    await ann.close()

    # ---- a failed announcement, then the next poll ---------------------
    FakeZeroconf.made.clear()
    NET.update(gateway=("10.0.0.1", "eth0"), addrs={"eth0": ["10.0.0.24"]})
    ann = new()
    FakeZeroconf.fail_next = 1
    await ann.refresh()
    check(not live()[0] and ann.announced == [], "a failed announcement: no record, the instance is closed")
    await ann.refresh()
    check(live()[1] == [["10.0.0.24"]], "the next poll announces again")
    await ann.close()
    # a failure that stays: a warning at the first try and again after WARN_EVERY polls
    warned = []
    handler = logging.Handler()
    handler.emit = lambda rec: warned.append(rec) if rec.levelno >= logging.WARNING else None
    logging.getLogger("tsx_panel.mdns").addHandler(handler)
    ann = new()
    FakeZeroconf.fail_next = mdns.WARN_EVERY + 1
    for _ in range(mdns.WARN_EVERY + 1):
        await ann.refresh()
    logging.getLogger("tsx_panel.mdns").removeHandler(handler)
    check(len(warned) == 2 and not live()[0], f"a failure that stays: {len(warned)} warnings in {mdns.WARN_EVERY + 1} tries (want 2)")
    FakeZeroconf.fail_next = 0
    await ann.close()

    # ---- the background poll -------------------------------------------
    FakeZeroconf.made.clear()
    NET.update(gateway=None, addrs={"eth0": []})
    ann = new(interval=0.05)
    await ann.register_server()
    check(not FakeZeroconf.made, "register_server() without an address: nothing announced, it waits")
    NET.update(gateway=("10.0.0.1", "eth0"), addrs={"eth0": ["10.0.1.24"]})
    await asyncio.sleep(0.3)
    check(live()[1] == [["10.0.1.24"]], "the poll announces the address of the lease by itself")
    NET["addrs"]["eth0"] = ["10.0.2.24"]
    await asyncio.sleep(0.3)
    check(live()[1] == [["10.0.2.24"]], "the poll follows an address change by itself")
    task = ann._task  # pylint: disable=protected-access
    await ann.close()
    check(task.done() and not live()[0], "close(): the poll has stopped and the record is withdrawn")

    # ---- the TXT of security.py ----------------------------------------
    os.environ["TSX_HA_API_KEY"] = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
    from tsx_panel import security  # noqa: WPS433

    security.enforce()
    FakeZeroconf.made.clear()
    NET.update(gateway=("10.0.0.1", "eth0"), addrs={"eth0": ["10.0.0.24"]})
    ann = new()
    await ann.refresh()
    info = FakeZeroconf.made[0].infos[0]
    check(info.properties.get(b"api_encryption") == security.NOISE_TXT.encode(),
          "the record carries api_encryption (security.py patches the ServiceInfo)")
    await ann.close()

    # ---- the voice satellite: tsx_lva._patch_listen --------------------
    import linux_voice_assistant  # noqa: WPS433

    lva_file = os.path.join(os.path.dirname(linux_voice_assistant.__file__), "__main__.py")
    check(lva_main_reads_globals(lva_file),
          "voice: LVA __main__.py imports get_default_ipv4 and HomeAssistantZeroconf at module level and main() reads them as globals")
    import tsx_lva  # noqa: WPS433

    lva_main = types.SimpleNamespace(get_default_ipv4=lambda iface: "10.0.0.24", HomeAssistantZeroconf=None)
    tsx_lva._patch_listen(lva_main, ["--name", "x", "--network-interface", "eth0", "--port", "6053"])  # pylint: disable=protected-access
    check(lva_main.get_default_ipv4("eth0") == "0.0.0.0", "voice: LVA listens on 0.0.0.0 without --host")
    # LVA's __main__: HomeAssistantZeroconf(port=, name=, mac_address=, host_ip_address=)
    FakeZeroconf.made.clear()
    NET.update(gateway=("192.168.7.1", "wlan0"), addrs={"eth0": ["10.0.0.5"], "wlan0": ["192.168.7.9"]})
    disc = lva_main.HomeAssistantZeroconf(port=6053, name="tsx-voice", mac_address="02:00:00:00:00:01",
                                          host_ip_address=lva_main.get_default_ipv4("eth0"))
    disc._zeroconf = FakeZeroconf  # pylint: disable=protected-access
    check(isinstance(disc, mdns.Announcer), "voice: the announcement is tsx_panel.mdns.Announcer")
    await disc.refresh()
    check(live()[1] == [["10.0.0.5"]], "voice: it announces the address of --network-interface eth0")
    await disc.close()
    lva_main = types.SimpleNamespace(get_default_ipv4=None, HomeAssistantZeroconf=None)
    tsx_lva._patch_listen(lva_main, ["--host", "10.9.8.7"])  # pylint: disable=protected-access
    FakeZeroconf.made.clear()
    disc = lva_main.HomeAssistantZeroconf(port=6053, name="tsx-voice", mac_address="02:00:00:00:00:01",
                                          host_ip_address="10.9.8.7")
    disc._zeroconf = FakeZeroconf  # pylint: disable=protected-access
    await disc.refresh()
    check(live()[1] == [["10.9.8.7"]], "voice: with --host the record holds that address")
    await disc.close()


if __name__ == "__main__":
    asyncio.run(main())
    print(("PASS" if not FAILS else f"FAIL ({len(FAILS)})") + " esphome-mdns-check", flush=True)
    sys.exit(1 if FAILS else 0)
