#!/usr/bin/env python3
"""Client-side check of the voice feature flags for tests/test-esphome.sh.

  esphome-voiceflags-check.py OFF_PORT ON_PORT NOMIC_PORT [--key BASE64]

OFF_PORT: tsx-esphome (VOICE=off) on a panel with a microphone.
ON_PORT:  the voice satellite code path (VOICE=on), noise-encrypted with --key.
NOMIC_PORT: tsx-esphome on a panel without a microphone (MIC=no).

Home Assistant (esphome integration, tag 2026.9.2) makes the voice selects
(pipelines, finished speaking detection, wake words) once for each setup of the
config entry, and only if device_info.voice_assistant_feature_flags_compat() is
not 0 at that time (select.py async_setup_entry). A later connection does not
add them (entry_data.py _ensure_platforms_loaded). The assist satellite follows
the flags at each connection (manager.py). HaEntry below is that logic. The
check connects to the servers in the order of a change of VOICE (off, on, off,
on) with the same aioesphomeapi client that Home Assistant uses.
"""
import argparse
import asyncio
import sys

from aioesphomeapi import APIClient
from aioesphomeapi.model import VoiceAssistantFeature


class HaEntry:
    """What the esphome integration of Home Assistant decides from the flags."""

    def __init__(self):
        self.select_platform_set_up = False
        self.voice_selects = False
        self.satellite = False
        self.wake_word_options = False

    def connect(self, flags):
        if not self.select_platform_set_up:          # entry_data.py: a platform is set up once
            self.select_platform_set_up = True
            self.voice_selects = bool(flags)         # select.py: async_setup_entry
        self.satellite = bool(flags)                 # manager.py: forwarded at each connection
        if self.satellite and flags & VoiceAssistantFeature.ANNOUNCE:
            self.wake_word_options = True            # assist_satellite.py: _update_satellite_config


async def flags_of(port, key, subscribe=False):
    client = APIClient("127.0.0.1", port, None, noise_psk=key)
    await client.connect(login=False)
    try:
        info = await client.device_info()
        flags = info.voice_assistant_feature_flags_compat(client.api_version)
        if subscribe:
            # what the assist satellite entity of Home Assistant does when it is added
            async def start(*_args):
                return None

            async def stop(_abort):
                return None

            client.subscribe_voice_assistant(handle_start=start, handle_stop=stop)
            await asyncio.sleep(0.5)
            await client.device_info()   # the connection still answers
        return VoiceAssistantFeature(flags)
    finally:
        await client.disconnect()


async def main(args) -> int:
    off = await flags_of(args.off_port, None, subscribe=True)
    on = await flags_of(args.on_port, args.key)
    nomic_flags = await flags_of(args.nomic_port, None)

    only = VoiceAssistantFeature.VOICE_ASSISTANT
    assert off == only, f"VOICE=off announces {off!r}, want only VOICE_ASSISTANT"
    print(f"OK: VOICE=off, microphone: voice_assistant_feature_flags {int(off)} (VOICE_ASSISTANT only, no ANNOUNCE, START_CONVERSATION or TIMERS)")
    want = VoiceAssistantFeature.VOICE_ASSISTANT | VoiceAssistantFeature.ANNOUNCE
    assert on & want == want, f"VOICE=on announces {on!r}"
    print(f"OK: VOICE=on: voice_assistant_feature_flags {int(on)}")
    assert bool(off) and bool(on), (off, on)
    print("OK: the flags are not 0 in both modes (the voice selects exist in both)")
    assert int(nomic_flags) == 0, nomic_flags
    print("OK: no microphone (MIC=no): no voice feature flags")

    # An entry that Home Assistant sets up while VOICE=off, and then VOICE=on, off, on
    entry = HaEntry()
    entry.connect(off)
    assert entry.voice_selects and entry.satellite and not entry.wake_word_options, vars(entry)
    entry.connect(on)
    assert entry.voice_selects and entry.satellite and entry.wake_word_options, vars(entry)
    entry.connect(off)
    entry.connect(on)
    assert entry.voice_selects and entry.satellite and entry.wake_word_options, vars(entry)
    print("OK: an entry set up with VOICE=off has the voice selects, and the wake word list arrives when VOICE=on")
    # A panel without a microphone has no voice entities at all
    nomic = HaEntry()
    nomic.connect(nomic_flags)
    assert not nomic.voice_selects and not nomic.satellite, vars(nomic)
    print("OK: an entry of a panel without a microphone has no voice entities")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("off_port", type=int)
    parser.add_argument("on_port", type=int)
    parser.add_argument("nomic_port", type=int)
    parser.add_argument("--key")
    sys.exit(asyncio.run(main(parser.parse_args())))
