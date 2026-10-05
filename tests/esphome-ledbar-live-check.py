#!/usr/bin/env python3
"""Client-side checks for tests/test-esphome-ledbar.sh: the LED bar entities
follow the USB LED bar while the ESPHome device runs. The script plays two
parts. It is a client like the ESPHome integration of Home Assistant: it
keeps one connection, and when the device ends it (expected or not) it
connects again and reads the entity list again. It also plays tsx-ledbard: it
writes and removes /run/tsx/ledbar.usb and ledbar.fw in RUN_DIR.

  esphome-ledbar-live-check.py PORT NAME RUN_DIR --mode follow   a bar at the start, then it goes and comes back
  esphome-ledbar-live-check.py PORT NAME RUN_DIR --mode later    no bar at the start, then a bar comes, then it goes
  esphome-ledbar-live-check.py PORT NAME RUN_DIR --mode hardoff  LEDBAR=no: a bar is attached, and there is never a light

The device must end the connection with a DisconnectRequest (an expected
disconnect: Home Assistant logs no error and connects again), and the device
information must stay the same.
"""
import argparse
import asyncio
import os
import sys

from aioesphomeapi import APIClient

FW13 = "firmware TSX-LEDBAR [v0.1.3]\neffects yes\nleds yes\ncaps tsx-ledbar fade blink breathe rainbow smooth cap status leds16 chase fill spectrum split\n"
FW12 = "firmware TSX-LEDBAR [v0.1.2]\neffects yes\nleds no\ncaps tsx-ledbar fade blink breathe rainbow smooth cap status\n"
ZONE = {"Chase", "Fill", "Spectrum"}
ACTIONS = {"ledbar_set_led", "ledbar_set_side", "ledbar_fill", "ledbar_split", "ledbar_clear"}


class Session:
    """One long-lived client, like the ESPHome integration of Home Assistant."""

    def __init__(self, port, name):
        self.port, self.name = port, name
        self.client = None
        self.stops = asyncio.Queue()   # expected_disconnect of each end of a connection
        self.states = {}
        self.info = None
        self.entities = []
        self.services = []

    async def _on_stop(self, expected):
        await self.stops.put(expected)

    async def connect(self):
        self.client = APIClient("127.0.0.1", self.port, None)
        await self.client.connect(on_stop=self._on_stop, login=False)
        self.info = await self.client.device_info()
        assert self.info.name == self.name, self.info.name
        self.entities, self.services = await self.client.list_entities_services()
        self.states = {}
        self.client.subscribe_states(lambda st: self.states.__setitem__(st.key, st))

    def light(self):
        return next((e for e in self.entities if e.object_id == "ledbar"), None)

    def actions(self):
        return {s.name for s in self.services}

    async def wait_reconnect(self, why, timeout=12):
        """The device ends the connection, as the ESPHome devices do before a restart:
        expected_disconnect is True. Then connect again and read the list again."""
        try:
            expected = await asyncio.wait_for(self.stops.get(), timeout)
        except asyncio.TimeoutError:
            raise AssertionError(f"{why}: the device did not end the connection within {timeout} s") from None
        assert expected is True, f"{why}: the connection ended with an error, not a request to disconnect"
        old_info = self.info
        await asyncio.sleep(0.3)
        await self.connect()
        assert self.info == old_info, f"{why}: the device information changed: {old_info} -> {self.info}"
        print(f"OK: {why}: the device asked for a reconnect (expected disconnect), the device information is the same")

    async def stay(self, why, seconds=3.5):
        """No change of the entity list: the connection must stay."""
        try:
            expected = await asyncio.wait_for(self.stops.get(), seconds)
        except asyncio.TimeoutError:
            print(f"OK: {why}: no reconnect")
            return
        raise AssertionError(f"{why}: the device ended the connection (expected={expected})")

    async def close(self):
        if self.client is not None:
            await self.client.disconnect()


def plug(run_dir, fw=FW13):
    """What tsx-ledbard does when a bar with its application appears: the
    firmware file first, then the attached file."""
    with open(os.path.join(run_dir, "ledbar.fw"), "w", encoding="utf-8") as fobj:
        fobj.write(fw)
    with open(os.path.join(run_dir, "ledbar.usb"), "w", encoding="utf-8") as fobj:
        fobj.write("app\n")


def unplug(run_dir):
    for name in ("ledbar.usb", "ledbar.fw"):
        try:
            os.unlink(os.path.join(run_dir, name))
        except FileNotFoundError:
            pass


def bootloader(run_dir):
    unplug(run_dir)
    with open(os.path.join(run_dir, "ledbar.usb"), "w", encoding="utf-8") as fobj:
        fobj.write("bootloader\n")


def has_bar(sess, why, zone=True):
    light = sess.light()
    assert light is not None, f"{why}: no LED bar light"
    effects = set(light.effects)
    assert {"None", "Pulse", "Breathe", "Blink", "Rainbow"} <= effects, effects
    if zone:
        assert ZONE <= effects, f"{why}: zone effects missing: {effects}"
        assert sess.actions() == ACTIONS, f"{why}: actions {sorted(sess.actions())}"
    else:
        assert not effects & ZONE, f"{why}: zone effects without the 16 LEDs: {effects}"
        assert not sess.actions(), f"{why}: actions without the 16 LEDs: {sorted(sess.actions())}"
    print(f"OK: {why}: the LED bar light with {len(effects)} effects" + (f" and {len(sess.actions())} actions" if zone else ", no actions"))


def no_bar(sess, why):
    assert sess.light() is None, f"{why}: the LED bar light is listed"
    assert not sess.actions() & ACTIONS, f"{why}: LED bar actions are listed: {sorted(sess.actions())}"
    assert not any(e.object_id.startswith("ledbar") for e in sess.entities), f"{why}: a LED bar entity is listed"
    print(f"OK: {why}: no LED bar light, no LED bar actions")


async def light_state(sess, why):
    for _ in range(30):
        light = sess.light()
        if light is not None and light.key in sess.states:
            print(f"OK: {why}: the light has a state")
            return
        await asyncio.sleep(0.1)
    raise AssertionError(f"{why}: the light got no state")


async def main(args) -> int:
    run = args.run_dir
    sess = Session(args.port, args.name)
    await sess.connect()
    try:
        if args.mode == "follow":
            has_bar(sess, "bar at the start")
            key = sess.light().key
            await light_state(sess, "bar at the start")
            unplug(run)
            await sess.wait_reconnect("bar removed")
            no_bar(sess, "bar removed")
            bootloader(run)
            await sess.stay("bar in the bootloader (no light, as without a bar)")
            no_bar(sess, "bar in the bootloader")
            plug(run)
            await sess.wait_reconnect("bar back in the application")
            has_bar(sess, "bar back")
            assert sess.light().key == key, "the light has a new key"
            print("OK: bar back: the light has the same key as before")
            await light_state(sess, "bar back")
            # the firmware without the 16 LEDs (a new bar firmware, the same USB device)
            plug(run, FW12)
            await sess.wait_reconnect("firmware 0.1.2 (no 16 LEDs)")
            has_bar(sess, "firmware 0.1.2", zone=False)
            plug(run, FW13)
            await sess.wait_reconnect("firmware 0.1.3 (16 LEDs)")
            has_bar(sess, "firmware 0.1.3")
            await sess.stay("the same file again")
            # a command still reaches the bar
            sess.client.light_command(key=sess.light().key, state=True, rgb=(1.0, 0.0, 0.0), brightness=1.0)
            await asyncio.sleep(0.6)
            bootloader(run)    # a bar that goes to the bootloader gives no light
            await sess.wait_reconnect("application to bootloader")
            no_bar(sess, "application to bootloader")
        elif args.mode == "later":
            no_bar(sess, "no bar at the start")
            await sess.stay("no bar, still no bar")
            plug(run)
            await sess.wait_reconnect("bar plugged in")
            has_bar(sess, "bar plugged in")
            await light_state(sess, "bar plugged in")
            sess.client.light_command(key=sess.light().key, state=True, rgb=(0.0, 1.0, 0.0), brightness=1.0)
            await asyncio.sleep(0.6)
            unplug(run)
            await sess.wait_reconnect("bar removed")
            no_bar(sess, "bar removed")
        else:
            no_bar(sess, "LEDBAR=no, no bar")
            plug(run)
            await sess.stay("LEDBAR=no, a bar is plugged in")
            no_bar(sess, "LEDBAR=no, a bar is attached")
            bootloader(run)
            await sess.stay("LEDBAR=no, the bar goes to the bootloader")
            unplug(run)
            await sess.stay("LEDBAR=no, the bar is removed")
        return 0
    finally:
        await sess.close()


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("port", type=int)
    p.add_argument("name")
    p.add_argument("run_dir")
    p.add_argument("--mode", choices=("follow", "later", "hardoff"), required=True)
    try:
        sys.exit(asyncio.run(main(p.parse_args())))
    except AssertionError as err:
        print(f"FAIL: {err}")
        sys.exit(1)
