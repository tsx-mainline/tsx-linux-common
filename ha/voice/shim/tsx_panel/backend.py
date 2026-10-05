"""PanelBackend: reads and controls the panel's local state for the ESPHome
device (tsx-esphome, and the voice satellite's plugin). Mirrors
rootfs/overlay/usr/local/sbin/tsx-mqtt's shell functions/paths (ledbar_state,
key_leds_state, screen_state, als_state, volume_state, the R/IDLED/BCONF/KCONF/
ACONF/CARD/ASOUND env names) so both transports read the exact same state
files -- this is the "one backend"; tsx-mqtt
stays POSIX sh (busybox-only panel shell) while this is Python (the voice
satellite's own language), so the sharing is at the state-file/CLI level, not
literally one source file.

The seam to the base system: this module is part of the Home Assistant layer
(tsx-ha) and never touches the hardware itself. Every command goes to
tsx-panelctl, and the one value that needs a tool (the volume) comes from
`tsx-panelctl get`. The base system owns tsx-panelctl
(/usr/local/sbin/tsx-panelctl, see the "Profiles" docs of the board
repository).
The state files that tsx-buttons, tsx-als, tsx-ledbard and tsx-idled write
under /run/tsx are the event interface, and this module reads them directly.

Privilege: reads never need root (every state file/sysfs node the panel
already creates world-readable). Writes are different: tsx-blank signals
tsx-idled (root, pkill only works same-UID-or-root), tsx-keypad/
tsx-buttons.ctl and /run/tsx/brightness are root:root 0600/0755 (checked in
rootfs/src/tsx-buttons.c and tsx-idled.c), and tsx-config apply refuses to run
non-root. So the writes go through the tsx-panelctl FIFO, a small root helper
with a fixed command set. The FIFO is writable for root and for the group
kiosk, so tsx-esphome (root) and the voice satellite (tsx-voice, kiosk:audio)
use the same path.

Env overrides (all also read by tsx-mqtt; new ones only for this module):
  TSX_RUN_DIR (/run/tsx), TSX_IDLED_STATE (/run/tsx-idled.state),
  TSX_BUTTONS_CONF (/etc/tsx/buttons.conf), TSX_BUTTONS_BOARD_CONF
  (/etc/tsx/buttons-board.conf, the board layer of the keys), TSX_KIOSK_CONF (/etc/kiosk.conf),
  TSX_ALS_CONF (/etc/tsx/als.conf),
  TSX_BOARD_BIN (tsx-board),
  TSX_ASOUND_DIR (/proc/asound), TSX_BACKLIGHT_DIR (/sys/class/backlight),
  TSX_THERMAL_ZONE (/sys/class/thermal/thermal_zone0/temp),
  TSX_DEVTOOLS (127.0.0.1:9222, as buttons.conf's DEVTOOLS=),
  TSX_PANELCTL (/run/tsx/panelctl), TSX_PANELCTL_BIN (tsx-panelctl: the
  client of the base system for `get` and `has`), TSX_BOOT_VERBOSE_FLAG (/etc/tsx/
  boot-verbose, the flag file `tsx-config apply` leaves for BOOT_VERBOSE=1;
  the initramfs reads the same file, see tsx-config's own comment),
  TSX_ORIENTATION_FILE (/etc/tsx/orientation: the screen orientation as
  `tsx-config apply` leaves it for the initramfs and the kiosk; absent =
  landscape).
  Parts that only some boards have (an entity exists only when its state file
  or device does): the distance sensor, USB power, the PoE class and NFC
  tags. Their daemons are board glue and write the state files in
  TSX_RUN_DIR.
"""

import json
import logging
import os
import re
import socket
import subprocess
import time
import urllib.request
from pathlib import Path
from typing import Optional, Tuple

_LOGGER = logging.getLogger("tsx_panel.backend")

# Effects that run on the LED bar itself (bar firmware TSX-LEDBAR, `tsx-ledbar
# fx`): the Home Assistant effect name and the fx name. The stock firmware
# has none of them.
LEDBAR_FX = {"Breathe": "breathe", "Blink": "blink", "Rainbow": "rainbow"}
LEDBAR_FX_BREATHE_MS = 4000      # one breath
LEDBAR_FX_BLINK_MS = (500, 500)  # on, off
LEDBAR_FX_RAINBOW_MS = 10000     # one hue cycle
# The zone effects of the bar firmware TSX-LEDBAR 0.1.3 and later (16 LEDs,
# `tsx-panelctl has ledbar-leds`). Chase runs a dot of the light color down
# both sides. Fill is a level bar of the light color at full level, and the
# brightness of the light sets its height (0 to 100 %). Spectrum spreads the
# hue circle along the rows at the brightness of the light. The bar firmware
# also has a split effect (one color on each side). It is only an action
# (ledbar_split), because a light has one color.
LEDBAR_LEDS_FX = {"Chase": "chase", "Fill": "fill", "Spectrum": "spectrum"}
LEDBAR_FX_CHASE_MS = 1500        # one run from top to bottom
LEDBAR_FX_SPECTRUM_MS = 10000    # one hue cycle

# A LED selection of the bar firmware: R1 to R8 (right side), L1 to L8 (left
# side), top to bottom, the index 0 to 15, a range of two of them, R, L or ALL.
_LED_ONE = r"(?:[RL][1-8]|1[0-5]|[0-9])"
_LEDS_RE = re.compile(rf"^(?:ALL|R|L|{_LED_ONE}|{_LED_ONE}-{_LED_ONE})$")


def _env(name, default):
    return os.environ.get(name, default)


def _read_first_line(path) -> Optional[str]:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fobj:
            return fobj.readline().rstrip("\n")
    except OSError:
        return None


def _field(path, key) -> Optional[str]:
    """The rest of the first line "KEY ..." of a tsx-mqtt-style state file."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fobj:
            for line in fobj:
                if line.startswith(key + " "):
                    return line[len(key) + 1 :].rstrip("\n")
    except OSError:
        return None
    return None


def board_value(name) -> str:
    """A value of the board file (board.sh): the environment first, else
    `tsx-board get NAME`. Empty if the board does not define it."""
    val = os.environ.get(name, "")
    if val:
        return val
    return _board_run("get", name)


def board_call(name) -> str:
    """The output of a function of the board file (`tsx-board call NAME`).
    Empty if the board does not define it."""
    return _board_run("call", name)


def esphome_model(ha_model, family_model) -> str:
    """The model that the ESPHome device reports to Home Assistant.

    ha_model is tsx_board_ha_model of the board file. family_model is
    TSX_HA_MODEL, the name that a board gives when it has no better one.
    - The two are equal (the board gives only its family name, for example
      "fake"): "fake panel".
    - A board gives the model of the unit: the vendor and the model
      ("Crestron " and the model, unless the model starts with "Crestron").
    - The board gives only TSX_HA_MODEL: the same as the first case.
    """
    if ha_model and ha_model != family_model:
        return ha_model if ha_model.startswith("Crestron") else "Crestron " + ha_model
    name = ha_model or family_model
    return f"{name} panel" if name else ""


def _board_run(how, name) -> str:
    try:
        return subprocess.run(
            [os.environ.get("TSX_BOARD_BIN", "tsx-board"), how, name],
            check=False, capture_output=True, text=True, timeout=5,
        ).stdout.strip()
    except Exception:  # noqa: BLE001
        return ""


class PanelBackend:
    def __init__(self):
        self._fx_sent = None  # R G B (0..100) of the last effect that Home Assistant started
        self.run_dir = Path(_env("TSX_RUN_DIR", "/run/tsx"))
        self.idled_state = Path(_env("TSX_IDLED_STATE", "/run/tsx-idled.state"))
        self.buttons_conf = Path(_env("TSX_BUTTONS_CONF", "/etc/tsx/buttons.conf"))
        # the board layer of the keys (it comes before buttons.conf)
        self.buttons_board_conf = Path(_env("TSX_BUTTONS_BOARD_CONF", "/etc/tsx/buttons-board.conf"))
        self.kiosk_conf = Path(_env("TSX_KIOSK_CONF", "/etc/kiosk.conf"))
        # the board layer of kiosk.conf (it wins over kiosk.conf)
        self.panel_board_conf = Path(_env("TSX_PANEL_BOARD_CONF", "/etc/tsx/panel-board.conf"))
        self.als_conf = Path(_env("TSX_ALS_CONF", "/etc/tsx/als.conf"))
        self.orientation_file = Path(_env("TSX_ORIENTATION_FILE", "/etc/tsx/orientation"))
        self.backlight_dir = Path(_env("TSX_BACKLIGHT_DIR", "/sys/class/backlight"))
        self.thermal_zone = Path(_env("TSX_THERMAL_ZONE", "/sys/class/thermal/thermal_zone0/temp"))
        self.devtools = _env("TSX_DEVTOOLS", "127.0.0.1:9222")
        self.panelctl = Path(_env("TSX_PANELCTL", str(self.run_dir / "panelctl")))
        self.boot_verbose_flag = Path(_env("TSX_BOOT_VERBOSE_FLAG", "/etc/tsx/boot-verbose"))
        self.panelctl_bin = _env("TSX_PANELCTL_BIN", "tsx-panelctl")
        self._usb_pending: Optional[Tuple[bool, float]] = None
        self._last_tag: Optional[Tuple[str, str]] = None
        self._orientation_pending: Optional[Tuple[str, float]] = None
        self._last_key: Optional[Tuple[str, str]] = None
        self._blank_timeout_pending: Optional[Tuple[int, float]] = None
        self._verbose_boot_pending: Optional[Tuple[bool, float]] = None

    # ---- the seam: tsx-panelctl ---------------------------------------------
    def _panelctl(self, *args, timeout=5):
        """Run the client of tsx-panelctl (`get`, `has`). Returns (ok, text)."""
        try:
            res = subprocess.run(
                [self.panelctl_bin, *args], check=False, capture_output=True, text=True, timeout=timeout,
            )
        except Exception:  # noqa: BLE001
            return False, ""
        return res.returncode == 0, res.stdout.strip()

    def _ctl(self, *words) -> bool:
        """Hand one command to the tsx-panelctl FIFO (one whitespace-separated
        line; see that script for the whitelist). Never blocks: a missing
        reader makes the non-blocking open fail immediately (ENXIO), logged
        and otherwise ignored -- the panel keeps working, just without that
        one command applied.
        """
        line = " ".join(words) + "\n"
        try:
            fd = os.open(str(self.panelctl), os.O_WRONLY | os.O_NONBLOCK)
        except OSError:
            _LOGGER.warning("tsx-panelctl not listening (%s): %s", self.panelctl, words)
            return False
        try:
            os.write(fd, line.encode("utf-8"))
        finally:
            os.close(fd)
        return True

    # ---- LED bar -------------------------------------------------------------
    def ledbar_present(self) -> bool:
        """The panel has a USB LED bar (tsx-panelctl has ledbar)."""
        return self._panelctl("has", "ledbar")[0]

    def _ledbar_fx_record(self):
        """The running effect of ledbar.state ("fx NAME N... [WORD]"): (name, [numbers]), else None."""
        raw = (_field(self.run_dir / "ledbar.state", "fx") or "").split()
        if not raw or raw[0] == "none":
            return None
        # the numbers only: spectrum may end with the word ring or rows
        return raw[0], [int(x) for x in raw[1:] if x.isdigit()]

    def _ledbar_effect_rgb(self):
        """The color of the running effect on the bar, R G B 0..100, else None.
        The record of fade, blink, breathe and chase has it. Fill has it at the
        level of its height. Rainbow and spectrum are white at their level."""
        rec = self._ledbar_fx_record()
        if rec is None:
            return None
        name, nums = rec
        if name in ("fade", "blink", "breathe", "chase") and len(nums) >= 3:
            return tuple(nums[:3])
        if name == "fill" and len(nums) >= 4:   # the height shows as the brightness
            return tuple((x * nums[3] + 50) // 100 for x in nums[:3])
        if name in ("rainbow", "spectrum"):
            level = nums[1] if len(nums) > 1 else 100
            return (level, level, level)
        return None

    def get_ledbar(self, fx: bool = False):
        """(on, brightness 0..255, r,g,b 0..255) of what the bar shows. This is the
        wanted color from ledbar.state "want R G B" (0..100). With fx (the bar
        firmware has effects) a running effect shows its own color instead, because
        an effect does not change the wanted color."""
        raw = _field(self.run_dir / "ledbar.state", "want") or "0 0 0"
        try:
            r, g, b = (int(x) for x in raw.split()[:3])
        except ValueError:
            r = g = b = 0
        shown = self._ledbar_effect_rgb() if fx else None
        if shown is not None:
            r, g, b = shown
        mx = max(r, g, b)
        if mx <= 0:
            return False, 0, 0, 0, 0
        bri = (mx * 255 + 50) // 100
        rr = (r * 255 + mx // 2) // mx
        gg = (g * 255 + mx // 2) // mx
        bb = (b * 255 + mx // 2) // mx
        return True, bri, rr, gg, bb

    def ledbar_fx_present(self) -> bool:
        """The LED bar runs the firmware TSX-LEDBAR, which has effects
        (tsx-panelctl has ledbar-fx)."""
        return self._panelctl("has", "ledbar-fx")[0]

    def ledbar_leds_present(self) -> bool:
        """The LED bar firmware has the 16 LEDs and the zone effects
        (TSX-LEDBAR 0.1.3 and later, tsx-panelctl has ledbar-leds)."""
        return self._panelctl("has", "ledbar-leds")[0]

    def get_ledbar_effect(self) -> str:
        """The Home Assistant name of the effect that runs on the LED bar
        (ledbar.state "fx NAME ..."), else "None"."""
        raw = (_field(self.run_dir / "ledbar.state", "fx") or "").split()
        for effect, name in {**LEDBAR_FX, **LEDBAR_LEDS_FX}.items():
            if raw and raw[0] == name:
                return effect
        return "None"

    def _ledbar_fx_end(self, rgb) -> bool:
        """True when Home Assistant chose effect None with the color of the running
        effect. Then the bar goes back to the wanted color from before the effect."""
        if self._ledbar_fx_record() is None or not self.ledbar_fx_present():
            return False
        for ref in (self._ledbar_effect_rgb(), self._fx_sent):
            if ref is not None and all(abs(x - y) <= 1 for x, y in zip(rgb, ref)):
                return True
        return False

    def set_ledbar(self, on: bool, bri: int, r: int, g: int, b: int, effect: str = "None") -> None:
        """A color, or with an effect of LEDBAR_FX that effect in the color.
        A color ends an effect on the bar. Effect None with the color of the
        running effect ends the effect with "fx off": the bar shows the color from
        before the effect. The poll of the device then reports that color to Home Assistant."""
        if not on or bri <= 0:
            self._fx_sent = None
            self._ctl("ledbar", "off")
            return
        # HA 0..255 rgb + 0..255 brightness -> bar 0..100 per channel
        rr = (r * bri * 100 + 32512) // 65025
        gg = (g * bri * 100 + 32512) // 65025
        bb = (b * bri * 100 + 32512) // 65025
        fx = LEDBAR_FX.get(effect) or LEDBAR_LEDS_FX.get(effect)
        if fx is None and effect == "None" and self._ledbar_fx_end((rr, gg, bb)):
            self._fx_sent = None
            self._ctl("ledbar", "fx", "off")
            return
        self._fx_sent = (rr, gg, bb) if fx else None
        if fx == "breathe":
            self._ctl("ledbar", "fx", fx, str(rr), str(gg), str(bb), str(LEDBAR_FX_BREATHE_MS))
        elif fx == "blink":
            self._ctl("ledbar", "fx", fx, str(rr), str(gg), str(bb), *(str(ms) for ms in LEDBAR_FX_BLINK_MS))
        elif fx == "rainbow":
            self._ctl("ledbar", "fx", fx, str(LEDBAR_FX_RAINBOW_MS), str((bri * 100 + 127) // 255))
        elif fx == "chase":
            self._ctl("ledbar", "fx", fx, str(rr), str(gg), str(bb), str(LEDBAR_FX_CHASE_MS))
        elif fx == "fill":
            # the color at full level, the brightness is the height
            self._ctl("ledbar", "fx", fx, *(str((x * 100 + 127) // 255) for x in (r, g, b)),
                      str((bri * 100 + 127) // 255))
        elif fx == "spectrum":
            self._ctl("ledbar", "fx", fx, str(LEDBAR_FX_SPECTRUM_MS), str((bri * 100 + 127) // 255))
        else:
            self._ctl("ledbar", "set", str(rr), str(gg), str(bb))

    # ---- the actions of the 16 LEDs (bar firmware 0.1.3) ---------------------
    # Home Assistant calls them as the services esphome.<device>_ledbar_*
    # (device.py). Each one checks its arguments and raises ValueError with a
    # message for Home Assistant. Colors are levels 0 to 100, as on the bar.
    @staticmethod
    def _levels(*values):
        for v in values:
            if not isinstance(v, int) or isinstance(v, bool) or not 0 <= v <= 100:
                raise ValueError(f"{v!r} is not a level from 0 to 100")
        return [str(v) for v in values]

    def _send(self, *words) -> None:
        if not self._ctl(*words):
            raise RuntimeError("tsx-panelctl does not listen")

    def ledbar_set_led(self, led: str, red: int, green: int, blue: int) -> None:
        """Set LEDs of the pattern: one LED, a range, a side or ALL."""
        sel = str(led).strip().upper()
        if not _LEDS_RE.match(sel):
            raise ValueError(f"{led!r} is not a LED (R1 to R8, L1 to L8, 0 to 15), a range (R1-R4), R, L or ALL")
        self._send("ledbar", "led", sel, *self._levels(red, green, blue))

    def ledbar_set_side(self, side: str, red: int, green: int, blue: int) -> None:
        """Set one side of the pattern: R (right) or L (left)."""
        sel = {"R": "R", "RIGHT": "R", "L": "L", "LEFT": "L"}.get(str(side).strip().upper())
        if sel is None:
            raise ValueError(f"{side!r} is not a side (R or L)")
        self._send("ledbar", "side", sel, *self._levels(red, green, blue))

    def ledbar_fill(self, percent: int, red: int, green: int, blue: int) -> None:
        """The fill effect: a level bar of the color, PERCENT of the height."""
        levels = self._levels(red, green, blue, percent)
        self._send("ledbar", "fx", "fill", *levels)

    def ledbar_split(self, right_red: int, right_green: int, right_blue: int,
                     left_red: int, left_green: int, left_blue: int) -> None:
        """The split effect: one color on the right side, one on the left side."""
        self._send("ledbar", "fx", "split", *self._levels(right_red, right_green, right_blue,
                                                           left_red, left_green, left_blue))

    def ledbar_clear(self) -> None:
        """Drop the pattern: the bar shows the light color again."""
        self._send("ledbar", "clear")

    # ---- key LEDs --------------------------------------------------------------
    def key_leds_present(self) -> bool:
        """The keys have LEDs (tsx-buttons writes "leds yes" to buttons.state)."""
        return self._panelctl("has", "keyleds")[0]

    def get_keypad(self):
        """(on, level) of the Key LEDs light: the level while the screen is
        awake (buttons.state "led_awake": the override or the day or night
        level). The light does not follow the screen-off level, so it does not
        jump at each blank and wake. An older tsx-buttons without that line:
        the level on the LEDs now ("led")."""
        state = self.run_dir / "buttons.state"
        raw = _field(state, "led_awake") or _field(state, "led") or "0 unknown"
        try:
            level = int(raw.split()[0])
        except (ValueError, IndexError):
            level = 0
        return level > 0, level

    def set_keypad(self, on: bool, brightness: int) -> None:
        """Off keeps the keys dark, also while the screen is blank. On sets the
        level while the screen is awake. Both hold until `tsx-keypad led auto`."""
        if not on:
            self._ctl("keypad", "led", "off")
        else:
            self._ctl("keypad", "led", str(max(1, min(255, brightness))))

    # A screen-off level that Home Assistant just set, and when (see get_key_led_blank)
    _key_led_blank_pending: Optional[Tuple[int, float]] = None

    def get_key_led_blank(self) -> int:
        """The level of the key LEDs while the screen is blank, 0 to 255, as
        tsx-buttons uses it (buttons.state "led_blank": LED_BLANK of
        buttons.conf, or KEY_LED_BLANK of panel.conf). An older tsx-buttons
        without that line: LED_BLANK of buttons.conf. A value just set is
        reported until tsx-buttons has it (as get_blank_timeout)."""
        value = None
        raw = _field(self.run_dir / "buttons.state", "led_blank")
        try:
            if raw:
                value = int(raw.split()[0])
        except (ValueError, IndexError):
            value = None
        if value is None:
            value = 0
            try:
                for line in self.buttons_conf.read_text(encoding="utf-8", errors="replace").splitlines():
                    line = line.strip()
                    if line.startswith("LED_BLANK="):
                        value = int(line.split("=", 1)[1].split("#", 1)[0].strip().strip("'\""))
            except (OSError, ValueError):
                pass
        pending = self._key_led_blank_pending
        if pending and pending[0] != value and time.monotonic() - pending[1] < 10:
            return pending[0]
        self._key_led_blank_pending = None
        return value

    def set_key_led_blank(self, level: float) -> None:
        """Store the screen-off level in panel.conf (KEY_LED_BLANK). tsx-config
        apply hands it to tsx-buttons, which applies it at once."""
        level = max(0, min(255, int(round(level))))
        self._key_led_blank_pending = (level, time.monotonic())
        self._ctl("keypad", "led-blank", str(level))

    # ---- screen / backlight ------------------------------------------------
    def get_backlight_max(self) -> int:
        """The top level of the backlight. tsx-idled reports it ("max M" in
        brightness.state). Before that, BACKLIGHT_MAX of kiosk.conf and of the
        board file, then the
        max_brightness of the first backlight device. 31 is the last resort."""
        val = _field(self.run_dir / "brightness.state", "max")
        if not val:
            for conf in (self.kiosk_conf, self.panel_board_conf):
                try:
                    for line in conf.read_text(encoding="utf-8", errors="replace").splitlines():
                        line = line.strip()
                        if line.startswith("BACKLIGHT_MAX="):
                            val = line.split("=", 1)[1].split("#", 1)[0].strip()
                except OSError:
                    pass
        if not val:
            try:
                for dev in sorted(self.backlight_dir.iterdir()):
                    val = (dev / "max_brightness").read_text(encoding="utf-8").strip()
                    break
            except OSError:
                pass
        try:
            return int(val.split()[0]) if val else 31
        except (ValueError, IndexError):
            return 31

    def get_screen(self):
        """(on, level|None)."""
        line = _read_first_line(self.idled_state) or ""
        parts = line.split()
        if parts and parts[0] == "blank":
            return False, None
        if len(parts) >= 2 and parts[0] == "on":
            try:
                return True, int(parts[1])
            except ValueError:
                return True, None
        return True, None

    def set_screen(self, on: bool) -> None:
        self._ctl("blank", "off" if on else "on")

    def set_backlight(self, level: float) -> None:
        # the ESPHome number arrives as a float (5.0): tsx-idled and
        # tsx-panelctl's is_uint check both want a plain integer
        level = max(1, min(self.get_backlight_max(), int(round(level))))
        on, _ = self.get_screen()
        if on:
            self._ctl("brightness", str(level))

    # ---- ambient light / auto-brightness -------------------------------------
    def als_present(self) -> bool:
        """The sensor (als.conf) or its state file (als.state)."""
        return self.als_conf.is_file() or (self.run_dir / "als.state").is_file()

    def get_lux(self) -> float:
        raw = _field(self.run_dir / "als.state", "report") or "0"
        try:
            return float(raw.split()[0])
        except (ValueError, IndexError):
            return 0.0

    def get_als_auto(self) -> bool:
        raw = _field(self.run_dir / "als.state", "auto") or "off"
        return raw.split()[0] == "on" if raw else False

    def set_als_auto(self, on: bool) -> None:
        self._ctl("als", "auto", "on" if on else "off")

    # ---- presence (the distance sensor) ---------------------------
    def presence_present(self) -> bool:
        return (self.run_dir / "presence.state").is_file()

    def get_presence(self) -> bool:
        return (_field(self.run_dir / "presence.state", "present") or "off").split()[0] == "on"

    def get_distance(self) -> Optional[float]:
        """mm, or None while there is no target."""
        raw = _field(self.run_dir / "presence.state", "distance")
        try:
            return float(raw.split()[0]) if raw else None
        except (ValueError, IndexError):
            return None

    # ---- rear USB power (written by the daemons of the board) -------------------
    def usb_power_present(self) -> bool:
        return (self.run_dir / "usb-power.state").is_file()

    def get_usb_power(self) -> bool:
        value = (_field(self.run_dir / "usb-power.state", "power") or "on").split()[0] == "on"
        pending = self._usb_pending
        if pending and pending[0] != value and time.monotonic() - pending[1] < 5:
            return pending[0]       # the command is on its way to the GPIO line
        self._usb_pending = None
        return value

    def set_usb_power(self, on: bool) -> None:
        self._usb_pending = (on, time.monotonic())
        self._ctl("usbpower", "on" if on else "off")

    # ---- PoE class (written by the daemons of the board) ------------------------
    def poe_present(self) -> bool:
        return (self.run_dir / "poe.state").is_file()

    def get_poe_class(self) -> str:
        cls = (_field(self.run_dir / "poe.state", "class") or "").split()
        if cls and cls[0] == "plus":
            return "PoE+ (802.3at)"
        if cls and cls[0] == "standard":
            return "PoE (802.3af)"
        return "unknown"

    # ---- eMMC health (written by the daemons of the board) ----------------------
    def emmc_present(self) -> bool:
        return (self.run_dir / "emmc.state").is_file()

    def _emmc_code(self, key: str) -> Optional[int]:
        raw = _field(self.run_dir / "emmc.state", key)
        try:
            return int(raw.split()[0], 16) if raw else None
        except (ValueError, IndexError):
            return None

    def get_emmc_life(self, which: str) -> Optional[float]:
        """Percent of the life used, as the upper bound of the JEDEC band:
        0x01 = up to 10 %, ... 0x0a = up to 100 %, 0x0b = exceeded (110).
        None when the eMMC does not report it (0x00)."""
        code = self._emmc_code("life_" + which)
        return None if not code or code > 0x0B else float(code * 10)

    def get_emmc_eol(self) -> str:
        return {1: "normal", 2: "warning", 3: "urgent"}.get(self._emmc_code("eol") or 0, "unknown")

    # ---- NFC tags (tsx-nfcd) ------------------------------------------------------
    def nfc_present(self) -> bool:
        return self._panelctl("has", "nfc")[0]

    def poll_nfc_tag(self) -> Optional[str]:
        """The UID of a tag scanned since the last call, once; else None.
        The first read after start is not an event (as poll_key_event)."""
        count = _field(self.run_dir / "nfc.state", "count")
        uid = _field(self.run_dir / "nfc.state", "last") or "-"
        if count is None:
            return None
        cur = (count.strip(), uid.strip())
        first = self._last_tag is None
        if cur == self._last_tag:
            return None
        self._last_tag = cur
        return None if first else cur[1]

    # ---- verbose boot (BOOT_VERBOSE, panel.conf) ------------------------------
    def get_verbose_boot(self) -> bool:
        """Read back from the flag file `tsx-config apply` leaves for
        BOOT_VERBOSE=1 (the initramfs reads the same file; it cannot read
        panel.conf under /data), not panel.conf itself: panel.conf is
        root-only (mode 600), so the voice satellite's plugin (user kiosk)
        could not read it -- same reasoning as _configured_kiosk_url above.
        A value just set is reported until `apply` has written the flag file
        (same short pending window as get_blank_timeout, for the same reason:
        the voice satellite's path goes through the tsx-panelctl FIFO, not a
        synchronous call).
        """
        value = self.boot_verbose_flag.exists()
        pending = self._verbose_boot_pending
        if pending and pending[0] != value and time.monotonic() - pending[1] < 10:
            return pending[0]
        self._verbose_boot_pending = None
        return value

    def set_verbose_boot(self, on: bool) -> None:
        self._verbose_boot_pending = (on, time.monotonic())
        self._ctl("verbose-boot", "on" if on else "off")

    # ---- volume ------------------------------------------------------------
    def sound_card_present(self) -> bool:
        return self._panelctl("has", "sound")[0]

    def get_volume(self) -> float:
        """The speaker level in percent, from `tsx-panelctl get volume`."""
        ok, out = self._panelctl("get", "volume")
        if not ok:
            return 0.0
        try:
            return float(out.split()[0])
        except (ValueError, IndexError):
            return 0.0

    def set_volume(self, percent: float) -> None:
        percent = max(0, min(100, int(round(percent))))
        self._ctl("volume", str(percent))

    # ---- sensors -------------------------------------------------------------
    def get_cpu_temp(self) -> float:
        raw = _read_first_line(self.thermal_zone)
        try:
            return round(int(raw) / 1000.0, 1) if raw else 0.0
        except ValueError:
            return 0.0

    def get_uptime(self) -> float:
        raw = _read_first_line("/proc/uptime")
        try:
            return round(float(raw.split()[0]), 0) if raw else 0.0
        except (ValueError, IndexError, AttributeError):
            return 0.0

    def get_ip(self) -> str:
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.connect(("198.51.100.1", 1))  # TEST-NET-2; no packet sent (UDP)
                return sock.getsockname()[0]
        except OSError:
            return ""

    def get_touched_recently(self, recent_seconds: float = 30.0) -> bool:
        """True while the last real input (touch, front key, power key) is
        less than recent_seconds old: tsx-idled writes its epoch seconds to
        run_dir/last-input (at most once a second). Without that file (an
        older tsx-idled) it falls back to the last blank/wake transition.
        """
        raw = _read_first_line(self.run_dir / "last-input")
        if raw:
            try:
                return time.time() - int(raw.split()[0]) < recent_seconds
            except (ValueError, IndexError):
                pass
        on, _ = self.get_screen()
        if not on:
            return False
        try:
            age = time.time() - self.idled_state.stat().st_mtime
        except OSError:
            return on
        return age < recent_seconds

    # ---- blank timeout (tsx-idled) ------------------------------------------
    def _kiosk_conf_int(self, key: str, default: int) -> int:
        val = None
        try:
            for line in self.kiosk_conf.read_text(encoding="utf-8", errors="replace").splitlines():
                line = line.strip()
                if line.startswith(key + "="):
                    val = line.split("=", 1)[1].split("#", 1)[0].strip().strip("'\"")
        except OSError:
            pass
        try:
            return int(val) if val else default
        except ValueError:
            return default

    def get_blank_timeout(self) -> int:
        """Seconds without input before the screen goes dark (0 = never),
        as tsx-idled takes it: the runtime file `tsx-config apply` writes
        from panel.conf's BLANK_TIMEOUT, else kiosk.conf. A value just set
        is reported until apply has written it (a few seconds at most), so
        the Home Assistant number does not jump back meanwhile."""
        value = None
        raw = _read_first_line(self.run_dir / "blank-timeout")
        try:
            if raw and raw.strip():
                value = int(raw.split()[0])
        except ValueError:
            value = None
        if value is None:
            value = self._kiosk_conf_int("BLANK_TIMEOUT", 300)
        pending = self._blank_timeout_pending
        if pending and pending[0] != value and time.monotonic() - pending[1] < 10:
            return pending[0]
        self._blank_timeout_pending = None
        return value

    def set_blank_timeout(self, seconds: float) -> None:
        seconds = max(0, min(86400, int(round(seconds))))
        self._blank_timeout_pending = (seconds, time.monotonic())
        self._ctl("blank-timeout", str(seconds))

    # ---- screen orientation (ORIENTATION, panel.conf) -----------------------
    ORIENTATIONS = ("landscape", "portrait", "landscape-flipped", "portrait-flipped")

    def get_orientation(self) -> str:
        """Read back from the file `tsx-config apply` leaves on the root file
        system (world-readable; panel.conf itself is root-only, so the voice
        satellite's plugin could not read it). A value just set is reported
        until apply has written it (as get_blank_timeout)."""
        value = (_read_first_line(self.orientation_file) or "").strip()
        if value not in self.ORIENTATIONS:
            value = "landscape"
        pending = self._orientation_pending
        if pending and pending[0] != value and time.monotonic() - pending[1] < 10:
            return pending[0]
        self._orientation_pending = None
        return value

    def set_orientation(self, name: str) -> None:
        if name not in self.ORIENTATIONS:
            _LOGGER.warning("orientation %r refused", name)
            return
        self._orientation_pending = (name, time.monotonic())
        self._ctl("orientation", name)

    # ---- front keys --------------------------------------------------------
    def key_names(self):
        """The names of the keys: the `button` lines of the board layer and of
        buttons.conf. A name in both files counts once."""
        names = []
        for path in (self.buttons_board_conf, self.buttons_conf):
            try:
                lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
            except OSError:
                continue
            for line in lines:
                parts = line.split()
                if len(parts) >= 3 and parts[0] == "button" and parts[1] not in names:
                    names.append(parts[1])
        return names

    def poll_key_event(self) -> Optional[Tuple[str, str]]:
        """Returns (name, event_type) once per new press, else None. HA event
        types: press/long/double (tsx-buttons reports short/long/hold; hold
        repeats while held -- mapped to "long" again, "double" is unused
        today, see entities.KeyEventEntity).
        """
        raw = _field(self.run_dir / "buttons.state", "last")
        if not raw:
            return None
        parts = raw.split()
        if len(parts) < 2 or parts[0] == "none":
            return None
        cur = (parts[0], parts[1])
        if cur == self._last_key:
            return None
        first = self._last_key is None
        self._last_key = cur
        if first:
            return None  # first read after start: not a new event
        mapped = {"short": "press", "long": "long", "hold": "long"}.get(cur[1])
        if not mapped:
            return None
        return cur[0], mapped

    # ---- kiosk (Chromium DevTools) -------------------------------------------
    def _devtools_page(self):
        url = f"http://{self.devtools}/json"
        with urllib.request.urlopen(url, timeout=3) as resp:
            tabs = json.loads(resp.read().decode("utf-8"))
        for tab in tabs:
            if tab.get("type") == "page":
                return tab
        return None

    def _configured_kiosk_url(self) -> str:
        """KIOSK_URL as the kiosk session reads it: tsx-config's override
        (run_dir/kiosk.conf, world-readable, written by `tsx-config apply`)
        wins over /etc/kiosk.conf. panel.conf itself is root-only, so the
        voice satellite's plugin (kiosk user) could not read it."""
        url = ""
        for path in (self.kiosk_conf, self.run_dir / "kiosk.conf"):
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            for line in text.splitlines():
                line = line.strip()
                if line.startswith("KIOSK_URL="):
                    url = line.split("=", 1)[1].strip().strip("'\"")
        return url

    def get_kiosk_url(self) -> str:
        """The CONFIGURED start URL, not the page the browser shows right
        now: the live URL changes on every login redirect (HA's
        /auth/authorize?...) and dashboard click, and a Home Assistant text
        entity that echoed it back would save that transient URL as the new
        KIOSK_URL on the next edit. The live page URL is only the fallback
        when no KIOSK_URL is configured at all."""
        url = self._configured_kiosk_url()
        if url:
            return url
        try:
            page = self._devtools_page()
            if page:
                return page.get("url", "")
        except Exception:  # noqa: BLE001
            _LOGGER.debug("DevTools not reachable at %s", self.devtools, exc_info=True)
        return ""

    def set_kiosk_url(self, url: str) -> None:
        """Navigate the live page immediately, then persist (tsx-config, so
        it survives a restart/reinstall). Navigation first: persisting runs
        `tsx-config apply`, which may restart the process serving this
        entity (tsx-esphome) if other settings changed too."""
        self._navigate(url)
        self._ctl("config-url", url)

    def reload_page(self) -> None:
        page = None
        try:
            page = self._devtools_page()
        except Exception:  # noqa: BLE001
            _LOGGER.warning("DevTools not reachable at %s", self.devtools, exc_info=True)
            return
        if page:
            self._cdp_call(page["webSocketDebuggerUrl"], "Page.reload", {"ignoreCache": False})

    def _navigate(self, url: str) -> None:
        try:
            page = self._devtools_page()
        except Exception:  # noqa: BLE001
            _LOGGER.warning("DevTools not reachable at %s", self.devtools, exc_info=True)
            return
        if page:
            self._cdp_call(page["webSocketDebuggerUrl"], "Page.navigate", {"url": url})

    def _cdp_call(self, ws_url: str, method: str, params: dict) -> None:
        """One request/response over the page's own DevTools websocket.
        Synchronous (asyncio.to_thread'd by callers that are on the event
        loop): a page's own websocket only ever has one command in flight
        from us at a time, so a short-lived connection per call keeps this
        simple. Uses the `websockets` package already vendored for the voice
        satellite (see rootfs/voice/install-lva.sh); on the standalone
        tsx-esphome this needs the same PYTHONPATH (/opt/lva/lib) -- see
        tsx-esphome's launcher script.
        """
        import websockets.sync.client as ws_sync  # noqa: WPS433 (optional/heavy import kept local)

        try:
            with ws_sync.connect(ws_url, open_timeout=3, close_timeout=3) as ws:
                ws.send(json.dumps({"id": 1, "method": method, "params": params}))
                for _ in range(20):
                    msg = json.loads(ws.recv(timeout=3))
                    if msg.get("id") == 1:
                        return
        except Exception:  # noqa: BLE001
            _LOGGER.warning("CDP %s failed", method, exc_info=True)

    # ---- reboot --------------------------------------------------------------
    def reboot(self) -> None:
        self._ctl("reboot")

    # ---- update (tsx-autoupdate) ------------------------------------------
    def get_update_status(self) -> dict:
        """tsx-autoupdate's own HA-ready status (same file tsx-mqtt's
        update_state() reads: $TSX_RUN_DIR/update-ha-state.json), or a safe
        default before it has ever run -- see tsx-autoupdate's write_ha_json."""
        path = self.run_dir / "update-ha-state.json"
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {
                "installed_version": "unknown",
                "latest_version": "unknown",
                "title": "TSX packages",
                "release_summary": "tsx-autoupdate has not run yet",
                "in_progress": False,
            }

    def install_update(self) -> None:
        """"Install" on the Update entity: the same "tsx-autoupdate now"
        tsx-mqtt's Install runs -- right away, outside the night window (the
        window/idle gate still applies to the reboot itself)."""
        self._ctl("update-install")
