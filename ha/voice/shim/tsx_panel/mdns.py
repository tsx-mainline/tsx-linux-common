"""The mDNS announcement of the ESPHome API (`_esphomelib._tcp`) for both
front ends: tsx-esphome (esphome_server.py) and the voice satellite
(tsx_lva, in place of linux_voice_assistant.zeroconf.HomeAssistantZeroconf).

The record follows the IPv4 addresses of the interface. A panel that starts
before its DHCP lease has no address yet: it announces nothing and waits.
It never announces 0.0.0.0, because Home Assistant cannot connect to that
address. A new, changed or lost address replaces the record.

How: every POLL_SECONDS, read the addresses of the interface: the interface
of the default route (/proc/net/route), or a fixed one (IFACE=). Without a
default route, the interface of the last default route counts (a lease
without a router, the short gap while the route changes). The addresses come
from netifaces (getifaddrs, no process). On a change, close the zeroconf
instance and start a new one. A new instance is necessary: zeroconf opens
its sockets for the interface addresses that exist when it starts, so an
instance from before the lease sends only on the loopback interface. A poll
is enough here: an address changes rarely, and Home Assistant then sees the
new record within POLL_SECONDS plus the probe time. A netlink listener would
be faster but needs much more code.

With a fixed address (--host / HOST=, not 0.0.0.0) the record holds that
address only, as before. A network without a default route needs IFACE=.
"""

import asyncio
import contextlib
import logging
import os
import socket

_LOGGER = logging.getLogger("tsx_panel.mdns")

ANY = "0.0.0.0"
POLL_SECONDS = 5.0
SERVICE_TYPE = "_esphomelib._tcp.local."
WARN_EVERY = 12  # a failure that stays: a warning again after this many polls
_RTF_UP = 0x1


def default_interface():
    """The interface of the IPv4 default route with the lowest metric, or
    None (no lease yet). Read from /proc/net/route (test override
    TSX_ROUTE_FILE): the default_gateway() of netifaces2 0.0.22 and the
    helper of linux-voice-assistant run `ip` in new processes, and the
    helper prints a line at each call without a route."""
    best = None
    with open(os.environ.get("TSX_ROUTE_FILE", "/proc/net/route"), "r", encoding="ascii") as fobj:
        next(fobj, None)  # the header
        for line in fobj:
            cols = line.split()
            # Iface Destination Gateway Flags RefCnt Use Metric Mask ...
            if len(cols) < 8 or cols[1] != "00000000" or cols[7] != "00000000":
                continue
            if not int(cols[3], 16) & _RTF_UP:
                continue
            metric = int(cols[6])
            if best is None or metric < best[0]:
                best = (metric, cols[0])
    return best[1] if best else None


def interface_ipv4(iface):
    """The IPv4 addresses of iface (first the primary address), without
    0.0.0.0. [] for no interface, an unknown one or one without an address."""
    import netifaces  # noqa: WPS433

    if not iface:
        return []
    try:
        entries = netifaces.ifaddresses(iface).get(netifaces.AF_INET) or []
    except (ValueError, OSError):
        return []
    addrs = []
    for entry in entries:
        addr = entry.get("addr")
        if addr and addr != ANY and addr not in addrs:
            addrs.append(addr)
    return addrs


class Announcer:
    """The arguments of HomeAssistantZeroconf (linux-voice-assistant), so the
    voice satellite can use this class in its place. host_ip_address: a fixed
    address, or None / 0.0.0.0 for the addresses of `interface` (None: the
    interface of the default route at each poll).

    addresses and zeroconf replace the address source and the AsyncZeroconf
    class in the tests (tests/esphome-mdns-check.py).
    """

    def __init__(self, port, mac_address, host_ip_address=None, name=None, *,
                 interface=None, addresses=None, zeroconf=None, interval=POLL_SECONDS):
        self.port = port
        self.mac_address = mac_address
        self.name = name or mac_address
        self.interval = interval
        fixed = host_ip_address if host_ip_address and host_ip_address != ANY else None
        if addresses is None:
            addresses = (lambda: [fixed]) if fixed else self._interface_addresses
        self._addresses = addresses
        self._interface = interface
        self._last_iface = None  # the interface of the last default route
        self._zeroconf = zeroconf
        self._aiozc = None
        self._seen = None  # the address list of the last refresh
        self._failures = 0
        self._task = None
        self.announced = []  # the addresses in the record on the network now

    def _interface_addresses(self):
        iface = self._interface or default_interface() or self._last_iface
        self._last_iface = iface
        return interface_ipv4(iface)

    async def register_server(self) -> None:
        """Announce now if there is an address. Then follow the address in
        the background for the life of the process."""
        await self.refresh()
        self._task = asyncio.ensure_future(self._follow())

    async def close(self) -> None:
        task, self._task = self._task, None
        if task is not None:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
        await self._withdraw()

    async def _follow(self) -> None:
        while True:
            await asyncio.sleep(self.interval)
            try:
                await self.refresh()
            except Exception:  # noqa: BLE001 - the next poll tries again
                _LOGGER.warning("mDNS: refresh failed", exc_info=True)

    async def refresh(self) -> None:
        """Compare the addresses with the record and replace the record when
        they differ. A failed announcement is tried again at the next call.
        A failed read of the addresses changes nothing."""
        try:
            addrs = list(self._addresses())
        except Exception:  # noqa: BLE001 - keep the record as it is
            _LOGGER.warning("mDNS: cannot read the addresses", exc_info=True)
            return
        if addrs == self._seen and (not addrs or self._aiozc is not None):
            return
        if addrs != self._seen:
            self._failures = 0
        self._seen = addrs
        await self._withdraw()
        if not addrs:
            _LOGGER.info("mDNS: %s: no IPv4 address, not announced (waiting for an address)", self.name)
            return
        if self._zeroconf is None:
            from linux_voice_assistant import zeroconf as lva_zeroconf  # noqa: WPS433

            self._zeroconf = lva_zeroconf.AsyncZeroconf
        aiozc = None
        try:
            # a new instance: its sockets are the ones of the addresses now
            aiozc = self._zeroconf()
            await aiozc.async_register_service(self._info(addrs))
        except Exception as err:  # noqa: BLE001 - e.g. NonUniqueNameException, a socket error
            self._failures += 1
            (_LOGGER.warning if self._failures % WARN_EVERY == 1 else _LOGGER.debug)(
                "mDNS: could not announce %s at %s: %r (failure %d, next try in %ss)", self.name,
                ", ".join(addrs), err, self._failures, self.interval)
            if aiozc is not None:
                try:
                    await aiozc.async_close()
                except Exception:  # noqa: BLE001
                    pass
            return
        self._aiozc = aiozc
        self.announced = addrs
        _LOGGER.info("mDNS: %s announced at %s port %s", self.name, ", ".join(addrs), self.port)

    async def _withdraw(self) -> None:
        """Close the zeroconf instance. It sends the goodbye of the record."""
        aiozc, self._aiozc = self._aiozc, None
        if aiozc is None:
            return
        old, self.announced = self.announced, []
        try:
            await aiozc.async_close()
        except Exception:  # noqa: BLE001 - the address can be gone already
            _LOGGER.debug("mDNS: closing the record of %s failed", ", ".join(old), exc_info=True)
        _LOGGER.info("mDNS: %s withdrawn from %s", self.name, ", ".join(old))

    def _info(self, addrs):
        # AsyncServiceInfo from the module of linux-voice-assistant: security.py patches it there
        from linux_voice_assistant import zeroconf as lva_zeroconf  # noqa: WPS433

        return lva_zeroconf.AsyncServiceInfo(
            SERVICE_TYPE,
            f"{self.name}.{SERVICE_TYPE}",
            addresses=[socket.inet_aton(addr) for addr in addrs],
            port=self.port,
            # the TXT record of linux_voice_assistant/zeroconf.py (1.1.15). security.py
            # adds api_encryption and friendly_name (its AsyncServiceInfo patch).
            properties={"version": "2025.9.0", "mac": self.mac_address, "board": "host",
                        "platform": "HOST", "network": "ethernet"},
            server=f"{self.name}.local.",
        )
