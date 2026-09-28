#!/usr/bin/env python3
"""Client-side checks for rootfs/tests/test-esphome.sh: connects to the
tsx-esphome standalone server under test with aioesphomeapi (the same client
library Home Assistant's ESPHome integration uses) and exercises the panel
entity list PLAN.md section 18 asks for: list entities, toggle the LED bar
light, set the kiosk URL text, receive a key-press event.
"""
import asyncio
import sys

from aioesphomeapi import APIClient


async def main(port: int) -> int:
    client = APIClient("127.0.0.1", port, None)
    await client.connect(login=False)
    try:
        info = await client.device_info()
        assert info.name == "test-panel", info.name

        entities, _services = await client.list_entities_services()
        by_id = {e.object_id: e for e in entities}
        want = {
            "ledbar", "keypad", "screen", "backlight", "kiosk_url",
            "reload_page", "reboot", "cpu_temp", "uptime", "ip_address",
            "touched_recently", "key_power", "key_home",
        }
        missing = want - by_id.keys()
        assert not missing, f"missing entities: {missing}"
        print(f"OK: {len(entities)} entities, all expected object_ids present")

        states = {}
        got_state = asyncio.Event()

        def on_state(state):
            states[state.key] = state
            got_state.set()

        client.subscribe_states(on_state)
        await asyncio.sleep(0.5)

        client.light_command(
            key=by_id["ledbar"].key, state=True, rgb=(1.0, 0.0, 0.0), brightness=1.0, color_mode=35,
        )
        await asyncio.sleep(0.5)
        light_state = states.get(by_id["ledbar"].key)
        assert light_state is not None and light_state.state and light_state.red == 1.0, light_state
        print("OK: LED bar light toggled on (red)")

        text_state = states.get(by_id["kiosk_url"].key)
        assert text_state is not None and text_state.state == "https://ha.example.org/configured", text_state
        print("OK: kiosk URL reports the configured URL, not the live page")

        client.text_command(key=by_id["kiosk_url"].key, state="https://ha.example.org/lovelace/0")
        await asyncio.sleep(0.5)
        text_state = states.get(by_id["kiosk_url"].key)
        assert text_state is not None and text_state.state == "https://ha.example.org/lovelace/0", text_state
        print("OK: kiosk URL text set")

        client.number_command(by_id["backlight"].key, 5.0)
        await asyncio.sleep(0.5)
        print("OK: backlight number sent (5.0; test-esphome.sh checks the brightness file)")

        # test-esphome.sh rewrites the fixture's buttons.state "last" line
        # after this point, to simulate a front-key press; give the daemon's
        # 1 s poll loop a couple of ticks to notice it.
        key_state = None
        for _ in range(40):
            await asyncio.sleep(0.25)
            key_state = states.get(by_id["key_home"].key)
            if key_state is not None:
                break
        assert key_state is not None and key_state.event_type == "long", key_state
        print("OK: key_home press received as an event (long)")
    finally:
        await client.disconnect()
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main(int(sys.argv[1]))))
