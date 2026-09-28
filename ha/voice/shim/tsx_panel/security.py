"""Restrict the ESPHome API to allowed peers (HA_ALLOW_FROM, panel.conf).

The ESPHome native API has no encryption or password in this setup (no
`api:` `encryption_key`, see docs/ha.md "One Home Assistant device" for the
noise-encryption follow-up), yet it now exposes a Reboot button and the
kiosk URL alongside the voice satellite's own entities. Empty HA_ALLOW_FROM
(the default) keeps the original zero-config behaviour -- anyone who can
reach port 6053 may use it, same as before this feature; setting it to the
Home Assistant host's address(es) closes that off.

Enforced in exactly one place for both front ends: patches
linux_voice_assistant.api_server.APIServer.connection_made /
.data_received, the base class BOTH tsx-esphome's PanelAPIServer and the
voice satellite's VoiceSatelliteProtocol subclass -- see
esphome_server.py's and tsx_lva/__init__.py's calls to enforce(). A denied
peer's connection is closed immediately and a `_tsx_denied` flag makes the
patched data_received a no-op for it too, so a few bytes that raced in
before the close() completes are never parsed/dispatched either.
"""

import ipaddress
import logging
import os

_LOGGER = logging.getLogger("tsx_panel.security")
_PATCHED = False


def allow_list():
    """[ip_network, ...] from HA_ALLOW_FROM, via the same world-readable
    override tsx_lva/__init__.py's _ha_transport() reads (panel.conf itself
    is mode 600; the voice satellite runs as kiosk:audio and cannot open
    it). Test override: TSX_HA_ALLOW_FROM. Invalid entries are ignored
    (logged), not fatal -- tsx-config's own validator is the first line of
    defense, this is the authoritative one.
    """
    override = os.environ.get("TSX_HA_ALLOW_FROM")
    if override is not None:
        raw = override
    else:
        raw = ""
        path = os.environ.get("TSX_ESPHOME_RUN_CONF", "/run/tsx/esphome.conf")
        try:
            with open(path, "r", encoding="utf-8") as fobj:
                for line in fobj:
                    line = line.strip()
                    if line.startswith("ALLOW_FROM="):
                        raw = line.split("=", 1)[1].strip('"')
        except OSError:
            pass
    nets = []
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        try:
            nets.append(ipaddress.ip_network(item, strict=False))
        except ValueError:
            _LOGGER.warning("HA_ALLOW_FROM: ignoring invalid entry %r", item)
    return nets


def peer_allowed(host) -> bool:
    nets = allow_list()
    if not nets:
        return True  # empty = allow any (the zero-config default)
    try:
        addr = ipaddress.ip_address(host)
    except ValueError:
        return False
    return any(addr in net for net in nets)


def enforce() -> None:
    """Idempotent per process: safe to call from both tsx-esphome and the
    voice satellite plugin (tsx_lva always calls it; esphome_server.py
    always calls it too), and safe to call more than once.
    """
    global _PATCHED  # noqa: PLW0603
    if _PATCHED:
        return
    _PATCHED = True

    from linux_voice_assistant.api_server import APIServer  # noqa: WPS433

    orig_connection_made = APIServer.connection_made
    orig_data_received = APIServer.data_received

    def connection_made(self, transport):
        orig_connection_made(self, transport)
        self._tsx_denied = False  # pylint: disable=protected-access
        peer = transport.get_extra_info("peername")
        host = peer[0] if peer else None
        if host is not None and not peer_allowed(host):
            _LOGGER.warning("tsx_panel: closing connection from %s (not in HA_ALLOW_FROM)", host)
            self._tsx_denied = True  # pylint: disable=protected-access
            transport.close()

    def data_received(self, data):
        if getattr(self, "_tsx_denied", False):
            return
        orig_data_received(self, data)

    APIServer.connection_made = connection_made
    APIServer.data_received = data_received
