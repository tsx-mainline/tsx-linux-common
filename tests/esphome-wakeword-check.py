#!/usr/bin/env python3
"""Client side of tests/test-esphome-wakewords.sh: the wake word list of the
voice satellite in Home Assistant when a custom model comes and goes.

It connects the way the ESPHome integration of Home Assistant 2026.9 does:
aioesphomeapi ReconnectLogic, and at each connect the voice assistant
configuration (esphome/assist_satellite.py _update_satellite_config, which
runs when the assist_satellite entity is added after each connect).

  esphome-wakeword-check.py PORT CUSTOM_DIR STOCK_DIR

STOCK_DIR is the wakewords folder of linux-voice-assistant. The check copies
a stock model as the custom model my_word, the way scp does: first the
.json file, then the .tflite file in parts.
"""
import argparse
import asyncio
import json
import os
import sys
import time

from aioesphomeapi import APIClient, ReconnectLogic

STOCK_MICRO = {"alexa", "choo_choo_homie", "hey_home_assistant", "hey_jarvis", "hey_luna", "hey_morgan",
               "hey_mycroft", "okay_computer", "okay_nabu"}
STOCK_OWW = {"alexa_v0.1", "hey_jarvis_v0.1", "hey_mycroft_v0.1", "hey_rhasspy_v0.1", "ok_nabu_v0.1"}


async def main(args) -> int:
    client = APIClient("127.0.0.1", args.port, None)
    configs = []  # one (available {id: text}, active ids) per connect
    disconnects = []

    async def on_connect():
        await client.device_info()
        cfg = await client.get_voice_assistant_configuration(5, external_wake_words=[])
        configs.append(({w.id: w.wake_word for w in cfg.available_wake_words}, list(cfg.active_wake_words)))

    async def on_disconnect(expected):
        disconnects.append(expected)

    async def wait_configs(count, timeout):
        end = time.monotonic() + timeout
        while len(configs) < count and time.monotonic() < end:
            await asyncio.sleep(0.1)
        assert len(configs) >= count, f"{len(configs)} connects, want {count} (configs {configs})"

    async def stays(count, seconds):
        await asyncio.sleep(seconds)
        assert len(configs) == count, f"{len(configs)} connects, want {count} (configs {configs})"

    logic = ReconnectLogic(client=client, on_connect=on_connect, on_disconnect=on_disconnect, name=None)
    await logic.start()
    try:
        await wait_configs(1, 20)
        ids, active = configs[0]
        assert set(ids) == STOCK_MICRO | STOCK_OWW, f"stock list: {sorted(ids)}"
        assert active == ["okay_nabu"], active
        print(f"OK: start: {len(ids)} stock wake words pass the check, okay_nabu active")

        # a new model, copied the way scp copies it
        cfg = json.load(open(os.path.join(args.stock, "hey_luna.json"), encoding="utf-8"))
        cfg.update(wake_word="My Word", model="my_word.tflite")
        with open(os.path.join(args.custom, "my_word.json"), "w", encoding="utf-8") as fobj:
            json.dump(cfg, fobj)
        await asyncio.sleep(0.2)
        data = open(os.path.join(args.stock, "hey_luna.tflite"), "rb").read()
        with open(os.path.join(args.custom, "my_word.tflite"), "wb") as fobj:
            for part in range(4):
                fobj.write(data[part * len(data) // 4:(part + 1) * len(data) // 4])
                fobj.flush()
                await asyncio.sleep(0.2)
        start = time.monotonic()
        await wait_configs(2, 20)
        ids, active = configs[1]
        assert ids.get("my_word") == "My Word" and active == ["okay_nabu"], configs[1]
        print(f"OK: add: Home Assistant connects again and gets my_word ({time.monotonic() - start:.1f} s after the copy)")
        await stays(2, 6)
        print("OK: add: one reconnect for the two files")

        # Home Assistant selects it (the wake word select)
        await client.set_voice_assistant_configuration(["my_word"])
        cfg = await client.get_voice_assistant_configuration(5, external_wake_words=[])
        assert list(cfg.active_wake_words) == ["my_word"], cfg.active_wake_words
        print("OK: select: my_word is active")

        # a bad model: no change in the list, no reconnect
        with open(os.path.join(args.custom, "broken.json"), "w", encoding="utf-8") as fobj:
            fobj.write('{"type": "micro", "wake_word": ')
        await stays(2, 6)
        print("OK: bad model: no reconnect")

        # the active model goes away: back to okay_nabu, two reconnects
        os.remove(os.path.join(args.custom, "my_word.json"))
        os.remove(os.path.join(args.custom, "my_word.tflite"))
        await wait_configs(3, 20)
        ids, active = configs[2]
        assert "my_word" not in ids and active == ["okay_nabu"], configs[2]
        print("OK: remove: Home Assistant gets the list without my_word, okay_nabu active")
        await wait_configs(4, 15)
        assert configs[3] == configs[2], configs[3]
        await stays(4, 5)
        print("OK: remove: a second reconnect after the fallback, then no more")
        assert disconnects and not any(disconnects), f"disconnects (expected?) {disconnects}"
        print(f"OK: {len(disconnects)} disconnects, all unexpected (no reconnect delay in Home Assistant)")
    finally:
        await logic.stop()
        await client.disconnect()
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("port", type=int)
    parser.add_argument("custom")
    parser.add_argument("stock")
    try:
        sys.exit(asyncio.run(main(parser.parse_args())))
    except AssertionError as err:
        print(f"FAIL: {err}")
        sys.exit(1)
