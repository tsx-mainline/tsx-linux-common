#!/usr/bin/env python3
"""Client-side check of the device information for tests/test-esphome.sh.

  esphome-deviceinfo-check.py OFF_PORT ON_PORT

OFF_PORT: tsx-esphome (VOICE=off). ON_PORT: the voice satellite code path
(VOICE=on). Both run with the same panel name, the same MAC address and the
same Bluetooth settings. Home Assistant builds the device page (manufacturer,
model, software version) from the DeviceInfoResponse at each connection. So
every field of the response must be the same in both modes. Only the voice
feature flags differ (docs/esphome.md, "Voice features").
"""
import asyncio
import sys

from aioesphomeapi import APIClient

VOICE_FIELDS = {"voice_assistant_feature_flags", "legacy_voice_assistant_version"}


async def info(port):
    client = APIClient("127.0.0.1", port, None)
    await client.connect(login=False)
    try:
        return await client.device_info()
    finally:
        await client.disconnect()


async def main(off_port, on_port) -> int:
    off, on = (await info(off_port)).to_dict(), (await info(on_port)).to_dict()
    assert off["voice_assistant_feature_flags"] != on["voice_assistant_feature_flags"], "the two ports serve the same mode"
    moved = {k: (off.get(k), on.get(k)) for k in off.keys() | on.keys() if k not in VOICE_FIELDS and off.get(k) != on.get(k)}
    assert not moved, f"fields that differ between VOICE=off and VOICE=on: {moved}"
    print(f"OK: the device information is the same with VOICE=off and VOICE=on ({len(off) - len(VOICE_FIELDS)} fields, only the voice feature flags differ)")
    assert off["project_name"] == "tsx-mainline.tsx-esphome", off["project_name"]
    assert off["manufacturer"] == "Crestron (mainline Linux)", off["manufacturer"]
    assert off["model"] == "xx60 panel", off["model"]
    assert off["project_name"].split(".") == ["tsx-mainline", "tsx-esphome"]  # the manufacturer and the model that Home Assistant shows
    print(f"OK: project {off['project_name']!r}, manufacturer {off['manufacturer']!r}, model {off['model']!r}, version {off['project_version']!r} (ESPHome {off['esphome_version']!r})")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main(int(sys.argv[1]), int(sys.argv[2]))))
