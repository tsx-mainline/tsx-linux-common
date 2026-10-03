#!/bin/sh
# Host test of the camera of tsx_panel (camera.py and device.py): the CAMERA
# modes (off, snapshot, live) and the hardware facts, the entity lists, the
# V4L2 structure sizes, the image requests of Home Assistant in live mode,
# and the snapshot button and the image requests in snapshot mode, with a
# fake frame source (TSX_CAMERA_FAKE). Small stand-ins replace aioesphomeapi, protobuf and
# linux_voice_assistant, so the test needs no network and no camera. The JPEG
# part needs numpy and libturbojpeg on the host. Without them the test checks
# that the camera stays off and says why.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/run" "$T/state" "$T/bl" "$T/stub/aioesphomeapi" "$T/stub/google/protobuf" "$T/stub/linux_voice_assistant"
export PYTHONDONTWRITEBYTECODE=1
# the stand-ins: every protobuf name is a class that keeps its keyword arguments
: > "$T/stub/aioesphomeapi/__init__.py"
cat > "$T/stub/aioesphomeapi/api_pb2.py" <<'PY'
_classes = {}
def __getattr__(name):
    if name.startswith("__"):
        raise AttributeError(name)
    if name not in _classes:
        _classes[name] = type(name, (), {"__init__": lambda self, **kw: self.__dict__.update(kw)})
    return _classes[name]
PY
: > "$T/stub/google/__init__.py"; : > "$T/stub/google/protobuf/__init__.py"
echo "class Message: pass" > "$T/stub/google/protobuf/message.py"
: > "$T/stub/linux_voice_assistant/__init__.py"
cat > "$T/stub/linux_voice_assistant/entity.py" <<'PY'
class ESPHomeEntity:
    def __init__(self, server):
        self.server = server

class LEDLightEntity(ESPHomeEntity):
    def __init__(self, server, key, name, object_id, effects=None, supports_rgb=True,
                 supports_brightness=True, on_changed=None, icon=""):
        ESPHomeEntity.__init__(self, server)
        self.key, self.name, self.object_id = key, name, object_id
        self.effects_list = list(effects) if effects else []
        self.is_on, self.brightness, self.red, self.green, self.blue = False, 1.0, 1.0, 1.0, 1.0
        self.effect = ""

    def update_on_changed(self, on_changed):
        self._on_changed = on_changed
PY
python3 - "$HERE/ha/voice/shim" "$T" <<'PY'
import ctypes, os, struct, sys, time
shim, t = sys.argv[1:3]
sys.path[:0] = [t + "/stub", shim]
os.environ.update(TSX_RUN_DIR=t + "/run", TSX_STATE_DIR=t + "/state", TSX_BACKLIGHT_DIR=t + "/bl",
                  TSX_KIOSK_CONF=t + "/none", TSX_BUTTONS_CONF=t + "/none", TSX_ALS_CONF=t + "/none",
                  TSX_ASOUND_DIR=t + "/none", TSX_IDLED_STATE=t + "/none", TSX_PANELCTL_BIN="/nonexistent",
                  TSX_THERMAL_ZONE=t + "/none")
from aioesphomeapi import api_pb2 as pb
from tsx_panel import camera
from tsx_panel import device as dev
from tsx_panel.backend import PanelBackend

fails = 0
def check(name, got, want):
    global fails
    if got == want:
        print("ok  ", name)
    else:
        print("FAIL", name, "got", repr(got), "want", repr(want)); fails += 1

def write(path, text):
    with open(path, "w") as f:
        f.write(text)

class Backend(PanelBackend):
    def _panelctl(self, *args, timeout=5):
        return False, ""

def fresh(conf=None, hw=None):
    """A new camera service for the files of this test."""
    for name, text in (("camera.conf", conf), ("hw.conf", hw)):
        path = t + "/run/" + name
        if text is None:
            if os.path.exists(path):
                os.remove(path)
        else:
            write(path, text)
    camera.SERVICE = None
    return camera.service()

# ---- the V4L2 structures: the sizes of the kernel headers ---------------------
ptr = ctypes.sizeof(ctypes.c_void_p)
check("v4l2_buffer size", ctypes.sizeof(camera._Buffer), 88 if ptr == 8 else 80)
check("v4l2_format size", ctypes.sizeof(camera._Format), 208 if ptr == 8 else 204)
check("v4l2_requestbuffers size", ctypes.sizeof(camera._RequestBuffers), 20)
check("v4l2_subdev_format size", ctypes.sizeof(camera._SubdevFormat), 88)
check("VIDIOC_DQBUF", hex(camera.VIDIOC_DQBUF), hex(0xc0585611 if ptr == 8 else 0xc0505611))
check("VIDIOC_SUBDEV_S_FMT", hex(camera.VIDIOC_SUBDEV_S_FMT), "0xc0585605")
check("UYVY fourcc", hex(camera.PIX_FMT_UYVY), "0x59565955")

# ---- the setting: off by default --------------------------------------------------
frame = t + "/frame.uyvy"
w, h = 640, 480
row = bytes(v for x in range(w // 2) for v in (128, (x * 2) % 256, 128, (x * 2 + 1) % 256))
with open(frame, "wb") as f:
    f.write(row * h)
os.environ["TSX_CAMERA_FAKE"] = frame

svc = fresh()
check("no camera.conf: off", (svc.enabled(), svc.why_off()), (False, "CAMERA is off in panel.conf"))
for text, want in (("on", "live"), ("live", "live"), ("snapshot", "snapshot"), ("off", "off"), ("", "off"),
                   ("yes", "off"), (" Snapshot ", "snapshot")):
    check("mode: CAMERA=%r is %s" % (text, want), camera.parse_mode(text), want)
check("mode: from camera.conf", fresh('CAMERA="snapshot"\n').mode, "snapshot")
svc = fresh('CAMERA="off"\n')
check("CAMERA=off: off", svc.enabled(), False)
svc = fresh('CAMERA="on"\n', "GOVERNMENT=1\nCAMERA=no\nREASON=government=1 (TSW-760-NC)\n")
check("hw.conf CAMERA=no: off, with the reason", (svc.enabled(), svc.why_off()),
      (False, "this panel has no camera (government=1 (TSW-760-NC))"))
d = dev.build_entities(None, Backend())
check("camera off: no camera entity", (d.camera_entity, [e for e in d.entities if isinstance(e, camera.CameraEntity)]), (None, []))
check("size: the default", fresh('CAMERA="on"\n').config.size, (1280, 720))
check("size: from camera.conf", fresh('CAMERA="on"\nSIZE="640x480"\n').config.size, (640, 480))
check("size: an unknown size is the default", fresh('SIZE="641x480"\n').config.size, (1280, 720))
check("fps: limited to 10", fresh('FPS="50"\n').config.fps, 10.0)
check("quality: limited to 100", fresh('QUALITY="500"\n').config.quality, 100)

missing = camera.encoder_missing()
if missing:
    svc = fresh('CAMERA="on"\nSIZE="640x480"\n')
    check("no JPEG encoder: off, with the reason", (svc.enabled(), svc.why_off()), (False, missing))
    print("skip  the image tests: " + missing)
    sys.exit(1 if fails else 0)

# ---- on: the entity and the images ------------------------------------------------
svc = fresh('CAMERA="on"\nSIZE="640x480"\nFPS="5"\n', "GOVERNMENT=0\nCAMERA=yes\n")
check("CAMERA=on: on", (svc.enabled(), svc.why_off()), (True, ""))
d = dev.build_entities(None, Backend())
cam = d.camera_entity
check("camera on: one camera entity, the last key", (cam is not None, d.entities[-1] is cam), (True, True))
check("live: no button and no time sensor", (d.camera_button, d.camera_time), (None, None))
live_key = cam.key
listed = list(cam.handle_message(pb.ListEntitiesRequest()))
check("ListEntitiesCameraResponse", [(type(m).__name__, m.object_id, m.key, m.name, m.icon) for m in listed],
      [("ListEntitiesCameraResponse", "camera", cam.key, "Camera", "mdi:camera")])
sub = list(cam.handle_message(pb.SubscribeHomeAssistantStatesRequest()))
check("subscribe: one empty image (a state without a capture)",
      [(type(m).__name__, m.key, m.data, m.done) for m in sub], [("CameraImageResponse", cam.key, b"", True)])
check("subscribe: no capture", svc.stats["starts"], 0)

class Conn:
    def __init__(self):
        self.msgs = []
    def send_messages(self, msgs):
        self.msgs.extend(msgs)

def wait_images(conn, count, limit=5.0):
    end = time.monotonic() + limit
    while time.monotonic() < end:
        if sum(1 for m in conn.msgs if m.done) >= count:
            break
        time.sleep(0.02)
    images, cur = [], b""
    for m in conn.msgs:
        cur += m.data
        if m.done:
            images.append(cur); cur = b""
    return images

check("another message is not for the camera", camera.handle_message(Conn(), pb.PingRequest()), False)
a = Conn()
t0 = time.monotonic()
check("CameraImageRequest single: handled", camera.handle_message(a, pb.CameraImageRequest(single=True, stream=False)), True)
img = wait_images(a, 1)
check("single: one image", len(img), 1)
check("single: a JPEG (SOI and EOI)", (img[0][:2], img[0][-2:]) if img else None, (b"\xff\xd8", b"\xff\xd9"))
sof = img[0].find(b"\xff\xc0") if img else -1
check("single: 640x480 baseline", struct.unpack(">HH", img[0][sof + 5:sof + 9])[::-1] if sof > 0 else None, (640, 480))
check("single: the chunks carry the key of the entity", {m.key for m in a.msgs}, {cam.key})
check("single: only the last chunk says done", [m.done for m in a.msgs][-1:], [True])

# a big image: more than one chunk, none above the API limit
svc.config.size = (1280, 720)
big = t + "/big.uyvy"
with open(big, "wb") as f:
    f.write(os.urandom(1280 * 720 * 2))
os.environ["TSX_CAMERA_FAKE"] = big
svc.fake = big
camera.IDLE_CLOSE = 0.3
time.sleep(0.5)          # the session of the small frame closes
end = time.monotonic() + 3
while svc.capturing and time.monotonic() < end:
    time.sleep(0.05)
check("idle: the capture stops after IDLE_CLOSE", svc.capturing, False)
b = Conn()
camera.handle_message(b, pb.CameraImageRequest(single=True, stream=False))
img = wait_images(b, 1)
check("big: one image in several chunks", (len(img), len(b.msgs) > 1), (1, True))
check("big: every chunk at most CHUNK bytes", max(len(m.data) for m in b.msgs) <= camera.CHUNK, True)
check("big: done only on the last chunk", [m.done for m in b.msgs], [False] * (len(b.msgs) - 1) + [True])

# the stream: one image per request, at most FPS images per second
c = Conn()
times = []
for _ in range(4):
    camera.handle_message(c, pb.CameraImageRequest(single=False, stream=True))
    wait_images(c, len(times) + 1)
    times.append(time.monotonic())
gaps = [round(b - a, 2) for a, b in zip(times, times[1:])]
check("stream: four images for four requests", len(wait_images(c, 4)), 4)
check("stream: at most FPS images per second", all(g >= 1.0 / svc.config.fps - 0.02 for g in gaps), True)

# two connections wait at the same time: one image for each
x, y = Conn(), Conn()
camera.handle_message(x, pb.CameraImageRequest(single=True, stream=False))
camera.handle_message(y, pb.CameraImageRequest(single=True, stream=False))
check("two connections: one image each", (len(wait_images(x, 1)), len(wait_images(y, 1))), (1, 1))
# a closed connection gets nothing
z = Conn()
with svc._lock:          # hold the worker, so the request is still open
    svc._waiting[z] = time.monotonic()
camera.connection_lost(z)
check("connection lost: its open request is dropped", z in svc._waiting, False)
check("stats: images were sent", svc.stats["images"] >= 7, True)
check("live: the button does nothing", (svc.press(), svc._press_at), (None, 0.0))

# ---- snapshot: the button, the time sensor, the image requests ------------------------
import hashlib
import re


def hashes(images):
    """Short hashes: a failed check prints these, not the JPEG bytes."""
    return [hashlib.sha256(i).hexdigest()[:8] for i in images]


os.environ["TSX_CAMERA_FAKE"] = frame
camera.SNAPSHOT_REPEAT = 1.0
svc = fresh('CAMERA="snapshot"\nSIZE="640x480"\n', "GOVERNMENT=0\nCAMERA=yes\n")
check("snapshot: on", (svc.enabled(), svc.mode), (True, "snapshot"))
d = dev.build_entities(None, Backend())
cam, button, taken = d.camera_entity, d.camera_button, d.camera_time
check("snapshot: camera, button and time sensor are the last three entities",
      d.entities[-3:] == [cam, button, taken] and None not in (cam, button, taken), True)
check("snapshot: the camera has the key of live mode", cam.key, live_key)
listed = [m for e in (cam, button, taken) for m in e.handle_message(pb.ListEntitiesRequest())]
check("snapshot: the entity list", [(type(m).__name__, m.object_id, m.name) for m in listed],
      [("ListEntitiesCameraResponse", "camera", "Camera"), ("ListEntitiesButtonResponse", "take_snapshot", "Take snapshot"),
       ("ListEntitiesTextSensorResponse", "last_snapshot", "Last snapshot")])
check("snapshot: the time sensor is a timestamp", listed[2].device_class, "timestamp")
st = list(taken.handle_message(pb.SubscribeHomeAssistantStatesRequest()))
check("snapshot: no snapshot yet: the time is unknown", [getattr(m, "missing_state", False) for m in st], [True])

def images_of(conn):
    return wait_images(conn, 0, 0)

e = Conn()
camera.handle_message(e, pb.CameraImageRequest(single=True, stream=False))
camera.handle_message(e, pb.CameraImageRequest(single=False, stream=True))
img = wait_images(e, 1, 2)
check("snapshot: before the first snapshot a request gets an empty image", img[:1], [b""])
check("snapshot: requests never open the camera", (svc.stats["starts"], svc.capturing), (0, False))

sent = []
def broadcast(msgs):
    sent.extend(msgs)

dev.poll(d, broadcast)
sent.clear()
t0 = time.monotonic()
list(button.handle_message(pb.ButtonCommandRequest(key=button.key)))
list(button.handle_message(pb.ButtonCommandRequest(key=button.key)))    # a second press during the snapshot
end = time.monotonic() + 5
while svc.snapshot is None and time.monotonic() < end:
    time.sleep(0.02)
time.sleep(0.3)
snap1 = svc.snapshot
check("snapshot: a press takes one snapshot (two quick presses: one)", (svc.stats["snapshots"], svc.stats["starts"]), (1, 1))
check("snapshot: the camera is closed after the snapshot", svc.capturing, False)
sof = snap1.jpeg.find(b"\xff\xc0") if snap1 else -1
check("snapshot: a 640x480 JPEG", struct.unpack(">HH", snap1.jpeg[sof + 5:sof + 9])[::-1] if sof > 0 else None, (640, 480))
iso = svc.last_snapshot_time() or ""
check("snapshot: the time is ISO 8601 in UTC", bool(re.match(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\+00:00$", iso)), True)
dev.poll(d, broadcast)
check("snapshot: the poll sends the new time once",
      [(type(m).__name__, m.state) for m in sent if getattr(m, "key", None) == taken.key], [("TextSensorStateResponse", iso)])

f = Conn()
for _ in range(3):
    camera.handle_message(f, pb.CameraImageRequest(single=True, stream=False))
    wait_images(f, len(images_of(f)) + 1, 2)
check("snapshot: three stills get the snapshot", hashes(images_of(f)), hashes([snap1.jpeg]) * 3)
check("snapshot: stills do not open the camera", svc.stats["starts"], 1)

h1 = hashes([snap1.jpeg])[0]
g = Conn()
camera.handle_message(g, pb.CameraImageRequest(single=True, stream=False))
check("snapshot: a still on the stream connection", hashes(wait_images(g, 1, 0.5)), [h1])
camera.handle_message(g, pb.CameraImageRequest(single=False, stream=True))
check("snapshot: a stream after a still gets the snapshot at once", hashes(wait_images(g, 2, 0.5)), [h1] * 2)
t1 = time.monotonic()
camera.handle_message(g, pb.CameraImageRequest(single=False, stream=True))
check("snapshot: the next stream request waits", hashes(wait_images(g, 3, 0.5)), [h1] * 2)
img = wait_images(g, 3, 3)
check("snapshot: after SNAPSHOT_REPEAT the stream gets the same snapshot again",
      (hashes(img), time.monotonic() - t1 >= camera.SNAPSHOT_REPEAT - 0.1), ([h1] * 3, True))
check("snapshot: the stream does not open the camera", svc.stats["starts"], 1)

# a new snapshot goes at once to the stream that waits
frame2 = t + "/frame2.uyvy"
with open(frame2, "wb") as fobj:
    fobj.write(bytes(v for x in range(w // 2) for v in (90, (x * 3) % 256, 170, (x * 3 + 1) % 256)) * h)
svc.fake = frame2
camera.handle_message(g, pb.CameraImageRequest(single=False, stream=True))
time.sleep(0.2)
t2 = time.monotonic()
list(button.handle_message(pb.ButtonCommandRequest(key=button.key)))
img = wait_images(g, 4, 3)
snap2 = svc.snapshot
check("snapshot: a second press: a new image", (svc.stats["snapshots"], snap2.number, snap2.jpeg != snap1.jpeg), (2, 2, True))
check("snapshot: the waiting stream gets the new snapshot at once",
      (hashes(img[3:]), time.monotonic() - t2 < camera.SNAPSHOT_REPEAT), (hashes([snap2.jpeg]), True))
check("snapshot: the camera is closed again", (svc.stats["starts"], svc.capturing), (2, False))

# a failed snapshot keeps the last one
svc.fake = t + "/missing.uyvy"
list(button.handle_message(pb.ButtonCommandRequest(key=button.key)))
end = time.monotonic() + 3
while svc.stats["errors"] == 0 and time.monotonic() < end:
    time.sleep(0.02)
time.sleep(0.1)
check("snapshot: a failed snapshot keeps the last one", (svc.stats["errors"], svc.snapshot is snap2, svc._press_at), (1, True, 0.0))
camera.connection_lost(g)
check("snapshot: connection lost: the connection is forgotten", (g in svc._asks, g in svc._sent), (False, False))
sys.exit(1 if fails else 0)
PY
echo "PASS test-shim-camera"
