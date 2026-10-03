#!/usr/bin/env python3
"""Client-side checks for tests/test-esphome-ledbar.sh: the LED bar of the
ESPHome device with the bar firmware TSX-LEDBAR 0.1.3 (the 16 LEDs). It
connects with aioesphomeapi (the client library of the ESPHome integration
of Home Assistant) and calls the actions the way Home Assistant does.

  esphome-ledbar-check.py PORT NAME --leds      0.1.3: zone effects and actions
  esphome-ledbar-check.py PORT NAME --no-leds   0.1.2: no zone effects, no actions

NAME is the device name. Home Assistant names an action
esphome.<NAME with "_" for "-">_<action> (build_service_name of the ESPHome
integration).
"""
import argparse
import asyncio
import sys

from aioesphomeapi import APIClient
from aioesphomeapi.model import SupportsResponseType, UserServiceArgType

ACTIONS = {
    "ledbar_set_led": [("led", UserServiceArgType.STRING), ("red", UserServiceArgType.INT),
                       ("green", UserServiceArgType.INT), ("blue", UserServiceArgType.INT)],
    "ledbar_set_side": [("side", UserServiceArgType.STRING), ("red", UserServiceArgType.INT),
                        ("green", UserServiceArgType.INT), ("blue", UserServiceArgType.INT)],
    "ledbar_fill": [("percent", UserServiceArgType.INT), ("red", UserServiceArgType.INT),
                    ("green", UserServiceArgType.INT), ("blue", UserServiceArgType.INT)],
    "ledbar_split": [(f"{s}_{c}", UserServiceArgType.INT) for s in ("right", "left") for c in ("red", "green", "blue")],
    "ledbar_clear": [],
}
ZONE_EFFECTS = {"Chase", "Fill", "Spectrum"}


async def main(args) -> int:
    client = APIClient("127.0.0.1", args.port, None)
    await client.connect(login=False)
    try:
        info = await client.device_info()
        assert info.name == args.name, info.name
        entities, services = await client.list_entities_services()
        light = next(e for e in entities if e.object_id == "ledbar")
        effects = set(light.effects)
        if not args.leds:
            assert not services, f"actions without the 16 LEDs: {[s.name for s in services]}"
            assert not effects & ZONE_EFFECTS, f"zone effects without the 16 LEDs: {effects & ZONE_EFFECTS}"
            assert {"Breathe", "Blink", "Rainbow"} <= effects, effects
            print("OK: 0.1.2: no actions, no zone effects, the effects of 0.1.2")
            return 0

        assert ZONE_EFFECTS <= effects, f"zone effects missing: {ZONE_EFFECTS - effects}"
        assert "Split" not in effects, "Split is an action only"
        print(f"OK: light effects {sorted(effects)}")
        by_name = {s.name: s for s in services}
        assert set(by_name) == set(ACTIONS), sorted(by_name)
        for name, want in ACTIONS.items():
            got = [(a.name, a.type) for a in by_name[name].args]
            assert got == want, f"{name}: {got}"
            assert by_name[name].supports_response == SupportsResponseType.STATUS, by_name[name].supports_response
        entity_keys = {e.key for e in entities}
        assert not entity_keys & {s.key for s in services}, "an action shares a key with an entity"
        prefix = "esphome." + info.name.replace("-", "_") + "_"
        print("OK: actions " + ", ".join(prefix + n for n in ACTIONS) + " (types string, int; status response)")

        async def run(name, data, ok=True, needle=""):
            # Home Assistant with SupportsResponseType.STATUS: a call id, it waits for the status
            res = await client.execute_service(by_name[name], data, return_response=False, timeout=5)
            assert res is not None, f"{name}: no response"
            assert res.success == ok, f"{name} {data}: success {res.success} {res.error_message!r}"
            assert needle in res.error_message, f"{name}: message {res.error_message!r}"
            print(f"OK: {name} {data}: " + ("done" if ok else f"refused ({res.error_message})"))

        await run("ledbar_set_led", {"led": "R3", "red": 100, "green": 0, "blue": 0})
        await run("ledbar_set_led", {"led": "r1-r4", "red": 1, "green": 2, "blue": 3})
        await run("ledbar_set_side", {"side": "L", "red": 0, "green": 0, "blue": 50})
        await run("ledbar_fill", {"percent": 60, "red": 0, "green": 100, "blue": 0})
        await run("ledbar_split", {"right_red": 100, "right_green": 0, "right_blue": 0,
                                   "left_red": 0, "left_green": 0, "left_blue": 100})
        await run("ledbar_clear", {})
        await run("ledbar_set_led", {"led": "R9", "red": 1, "green": 2, "blue": 3}, False, "'R9' is not a LED")
        await run("ledbar_set_led", {"led": "R3", "red": 101, "green": 2, "blue": 3}, False, "101 is not a level")
        await run("ledbar_set_side", {"side": "up", "red": 1, "green": 2, "blue": 3}, False, "is not a side")
        await run("ledbar_fill", {"percent": 150, "red": 1, "green": 2, "blue": 3}, False, "150 is not a level")
        # an older Home Assistant: no call id, no response
        assert await client.execute_service(by_name["ledbar_set_led"], {"led": "ALL", "red": 7, "green": 7, "blue": 7}) is None
        print("OK: a call without a call id gets no response")
        # the zone effects of the light
        client.light_command(key=light.key, state=True, rgb=(1.0, 0.0, 0.0), brightness=1.0, effect="Chase")
        await asyncio.sleep(0.3)
        client.light_command(key=light.key, effect="Fill", brightness=0.5)
        await asyncio.sleep(0.3)
        client.light_command(key=light.key, effect="Spectrum", brightness=0.4)
        await asyncio.sleep(0.5)
        print("OK: light commands Chase, Fill, Spectrum sent")
        return 0
    finally:
        await client.disconnect()


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("port", type=int)
    p.add_argument("name")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--leds", action="store_true")
    g.add_argument("--no-leds", dest="leds", action="store_false")
    try:
        sys.exit(asyncio.run(main(p.parse_args())))
    except AssertionError as err:
        print(f"FAIL: {err}")
        sys.exit(1)
