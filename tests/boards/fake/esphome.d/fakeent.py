"""fakeent.py: a plugin of the ESPHome device for the made-up board "fake"
(docs/esphome.md "Plugins"). No real part is behind it. The tests of the
esphome.d loader use it in place of the plugin of a real board.

It follows the shape of a part that has its own API message, for example a
camera:
  - an entity that shows in the entity list (fake_frame)
  - a button (fake_press) and a text sensor with a state getter (fake_stamp)
  - handle_message() takes SubscribeLogsRequest, a message that no other code
    of the device handles, and sends one log line back
  - connection_lost() records the connection

STATE holds what the tests read. The module is loaded once by each front end.
"""

from aioesphomeapi.api_pb2 import (  # pylint: disable=no-name-in-module
    CameraImageResponse,
    ListEntitiesCameraResponse,
    ListEntitiesRequest,
    SubscribeHomeAssistantStatesRequest,
    SubscribeLogsRequest,
    SubscribeLogsResponse,
)
from linux_voice_assistant.entity import ESPHomeEntity
from tsx_panel.entities import ButtonEntity, TextSensorEntity

STATE = {"requests": 0, "presses": 0, "stamp": "none", "lost": [], "frame_key": None}


class FrameEntity(ESPHomeEntity):
    def __init__(self, server, key):
        ESPHomeEntity.__init__(self, server)
        self.key, self.name, self.object_id, self.icon = key, "Fake frame", "fake_frame", "mdi:image"

    def handle_message(self, msg):
        if isinstance(msg, ListEntitiesRequest):
            yield ListEntitiesCameraResponse(object_id=self.object_id, key=self.key, name=self.name, icon=self.icon)
        elif isinstance(msg, SubscribeHomeAssistantStatesRequest):
            yield CameraImageResponse(key=self.key, data=b"", done=True)


def _press():
    STATE["presses"] += 1
    STATE["stamp"] = "press %d" % STATE["presses"]


def entities(server, key_for):
    frame = FrameEntity(server, key_for("fake_frame"))
    STATE["frame_key"] = frame.key
    button = ButtonEntity(server, key_for("fake_press"), "Fake press", "fake_press", press=_press)
    stamp = TextSensorEntity(server, key_for("fake_stamp"), "Fake stamp", "fake_stamp",
                             get_state=lambda: STATE["stamp"])
    return [frame, button, stamp]


def handle_message(conn, msg):
    if not isinstance(msg, SubscribeLogsRequest):
        return False
    STATE["requests"] += 1
    conn.send_messages([SubscribeLogsResponse(message=b"fake log line")])
    return True


def connection_lost(conn):
    STATE["lost"].append(conn)
