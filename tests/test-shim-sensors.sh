#!/bin/sh
# Host test of the sensor parts of tsx_panel/backend.py: presence,
# USB power, PoE class, NFC tags and the backlight range. Each part exists only
# when its state file is there. No network and no aioesphomeapi needed.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/run" "$T/bl/x"
export PYTHONDONTWRITEBYTECODE=1
python3 - "$HERE/ha/voice/shim" "$T" <<'PY'
import os, sys
shim, t = sys.argv[1:3]
sys.path.insert(0, shim)
os.environ.update(TSX_RUN_DIR=t + "/run", TSX_BACKLIGHT_DIR=t + "/bl",
                  TSX_KIOSK_CONF=t + "/none", TSX_PANELCTL_BIN="/nonexistent")
from tsx_panel.backend import PanelBackend, esphome_model
def w(name, text):
    open(f"{t}/run/{name}", "w").write(text)
b = PanelBackend()
assert not b.presence_present() and not b.usb_power_present() and not b.poe_present()
assert b.get_backlight_max() == 31
open(t + "/bl/x/max_brightness", "w").write("4095\n")
assert b.get_backlight_max() == 4095
w("brightness.state", "level 5\nmax 255\n")
assert b.get_backlight_max() == 255
w("presence.state", "present on\ndistance 640\n")
assert b.presence_present() and b.get_presence() is True and b.get_distance() == 640.0
w("presence.state", "present off\ndistance none\n")
assert b.get_presence() is False and b.get_distance() is None
w("usb-power.state", "power on\n"); assert b.usb_power_present() and b.get_usb_power() is True
w("poe.state", "class plus\n"); assert b.get_poe_class() == "PoE+ (802.3at)"
w("poe.state", "class standard\n"); assert b.get_poe_class() == "PoE (802.3af)"
w("nfc.state", "count 1\nlast 04:A1\n")
assert b.poll_nfc_tag() is None          # the first read is no scan
assert b.poll_nfc_tag() is None
w("nfc.state", "count 2\nlast 04:B2\n")
assert b.poll_nfc_tag() == "04:B2" and b.poll_nfc_tag() is None
# the model of the ESPHome device (a board that gives only its family name reports "<family> panel", a board that gives the model of the unit "Crestron <model>")
assert esphome_model("fake", "fake") == "fake panel"
assert esphome_model("", "other") == "other panel"
assert esphome_model("FAKE-100", "fake") == "Crestron FAKE-100"
assert esphome_model("Crestron FAKE-100", "fake") == "Crestron FAKE-100"
assert esphome_model("", "fake") == "fake panel"
assert esphome_model("", "") == ""
print("PASS test-shim-sensors")
PY
