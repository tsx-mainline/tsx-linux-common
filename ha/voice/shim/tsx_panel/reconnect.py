"""Ask the clients of the ESPHome API to reconnect.

A device sends its entity list only when Home Assistant connects. The API has
no message that says "the list changed". When the list changes (the LED bar
comes or goes, device.sync_ledbar), the device asks each client to
disconnect. A device does the same before it restarts after a firmware
change. The client library (aioesphomeapi) treats this as an expected
disconnect: Home Assistant logs no error and connects again after about 5
seconds. It then reads the new list, adds the new entities and removes the
entities that are gone (homeassistant/components/esphome, entry_data.py
async_update_static_infos). The device information stays the same, so Home
Assistant keeps the device.

ask() runs in any thread. The work runs in the thread of each connection.
"""

import logging

from aioesphomeapi.api_pb2 import DisconnectRequest, DisconnectResponse  # pylint: disable=no-name-in-module

_LOGGER = logging.getLogger("tsx_panel.reconnect")

CLOSE_AFTER = 2.0   # seconds: close the socket if the client does not answer


def _close(conn) -> None:
    transport = getattr(conn, "_transport", None)
    if transport is not None:
        transport.close()


def _ask_one(conn) -> None:
    if getattr(conn, "_transport", None) is None:
        return
    conn.send_messages([DisconnectRequest()])
    loop = getattr(conn, "_loop", None)
    if loop is not None:
        loop.call_later(CLOSE_AFTER, _close, conn)


def ask(connections) -> int:
    """Ask each connection to disconnect. Returns the number of connections
    that were asked."""
    asked = 0
    for conn in list(connections):
        loop = getattr(conn, "_loop", None)
        if loop is None or getattr(conn, "_transport", None) is None:
            continue
        loop.call_soon_threadsafe(_ask_one, conn)
        asked += 1
    if asked:
        _LOGGER.info("asked %d client(s) to reconnect (the entity list changed)", asked)
    return asked


def handle_response(conn, msg) -> bool:
    """True for the answer of a client to the request of ask(): the client
    closes the connection, and this closes it at once too."""
    if not isinstance(msg, DisconnectResponse):
        return False
    _close(conn)
    return True
