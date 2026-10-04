#!/usr/bin/env python3
"""Client-side check of the plugins of esphome.d for tests/test-esphome.sh. It
uses aioesphomeapi (the client library of Home Assistant) against a server
that loaded the fake plugin of the made-up board (boards/fake/esphome.d/
fakeent.py).

  esphome-plugin-check.py PORT present|absent

present: the entity list has the three entities of the plugin (fake_frame,
         fake_press, fake_stamp) with their fixed keys. The text sensor
         reports "none". A press of the button changes it to "press 1" in
         the next poll. The log request, which only the plugin handles,
         brings the log line of the plugin.
absent:  the entity list has none of them (the plugin did not load).
"""
import argparse
import asyncio
import sys

from aioesphomeapi import APIClient
from tsx_panel import keys

OBJECT_IDS = ("fake_frame", "fake_press", "fake_stamp")


async def main(args) -> int:
    client = APIClient("127.0.0.1", args.port, None)
    await client.connect(login=False)
    try:
        entities, _services = await client.list_entities_services()
        by_id = {e.object_id: e for e in entities}
        if args.mode == "absent":
            extra = set(OBJECT_IDS) & by_id.keys()
            assert not extra, f"entities of a plugin that did not load: {extra}"
            print(f"OK: {len(entities)} entities, none of the plugin")
            return 0
        missing = set(OBJECT_IDS) - by_id.keys()
        assert not missing, f"missing plugin entities: {missing}"
        wrong = {i: by_id[i].key for i in OBJECT_IDS if by_id[i].key != keys.stable_key(i)}
        assert not wrong, f"plugin entities without their fixed key: {wrong}"
        print(f"OK: {len(entities)} entities, the three entities of the plugin with their fixed keys")

        states = {}
        client.subscribe_states(lambda state: states.__setitem__(state.key, state))
        await asyncio.sleep(0.5)
        stamp = states.get(by_id["fake_stamp"].key)
        assert stamp is not None and stamp.state == "none", stamp
        print("OK: the text sensor of the plugin reports its state")

        client.button_command(by_id["fake_press"].key)
        for _ in range(40):
            await asyncio.sleep(0.1)
            stamp = states.get(by_id["fake_stamp"].key)
            if stamp is not None and stamp.state == "press 1":
                break
        assert stamp is not None and stamp.state == "press 1", stamp
        print("OK: the button of the plugin ran, and the poll sent the new state")

        lines = []
        unsubscribe = client.subscribe_logs(lines.append)
        for _ in range(30):
            await asyncio.sleep(0.1)
            if lines:
                break
        unsubscribe()
        assert lines and lines[0].message == b"fake log line", lines
        print("OK: a message that only the plugin handles got the answer of the plugin")
        return 0
    finally:
        await client.disconnect()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("port", type=int)
    parser.add_argument("mode", choices=("present", "absent"))
    sys.exit(asyncio.run(main(parser.parse_args())))
