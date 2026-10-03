#!/usr/bin/env python3
"""Voice-satellite code path for tests/test-esphome.sh, without the
audio/wake-word stack: runs the real tsx_lva patches (security.enforce(),
the ServerState name patch, the panel-entity plugin) and serves the REAL
linux_voice_assistant VoiceSatelliteProtocol on a port, exactly the way
linux_voice_assistant/__main__.py does (loop.create_server(lambda:
VoiceSatelliteProtocol(state))). Only the pieces that need hardware or
compiled wheels are no-op stand-ins: the wake-word engines
(pymicro_wakeword / pyopen_wakeword, stub modules below), the mpv players
and the wake/stop models. Same idea as the fake sysfs/CLI fixtures the
standalone test uses.

  esphome-lva-harness.py PORT      (env as for tsx_panel.esphome_server)

With TSX_HARNESS_WAKEWORDS=1 the harness builds the wake word list the way
__main__.py does: find_available_wake_words over the stock folder of LVA,
TSX_VOICE_WAKEWORDS and the openWakeWord folder, then load_wake_models for
okay_nabu (tests/test-esphome-wakewords.sh). The stub models then read the
.json files.
"""
import asyncio
import json
import logging
import os
import sys
import tempfile
import types
from pathlib import Path
from queue import Queue


def _stub_model(cls, wid, wake_word):
    obj = cls()
    obj.id, obj.wake_word, obj.is_active = wid, wake_word, False
    return obj


def _micro_from_config(config_path, libtensorflowlite_c_path=None):
    with open(config_path, "r", encoding="utf-8") as fobj:
        config = json.load(fobj)
    # pymicro-wakeword 2.5.0: the id is the name of the .tflite file
    return _stub_model(sys.modules["pymicro_wakeword"].MicroWakeWord, Path(config["model"]).stem, config["wake_word"])


def _oww_from_model(model_path, libtensorflowlite_c_path=None):
    return _stub_model(sys.modules["pyopen_wakeword"].OpenWakeWord, Path(model_path).stem, "")


def _stub_wakeword_modules():
    for mod_name, cls_names in (
        ("pymicro_wakeword", ("MicroWakeWord", "MicroWakeWordFeatures")),
        ("pyopen_wakeword", ("OpenWakeWord", "OpenWakeWordFeatures")),
    ):
        mod = types.ModuleType(mod_name)
        for cls_name in cls_names:
            setattr(mod, cls_name, type(cls_name, (), {
                "process_streaming": lambda self, audio: [],
                "from_config": staticmethod(_micro_from_config),
                "from_model": staticmethod(_oww_from_model),
            }))
        sys.modules[mod_name] = mod


class _NullPlayer:
    """Stands in for MpvMediaPlayer: accepts every call, plays nothing."""

    is_playing = False

    def __getattr__(self, _name):
        return lambda *args, **kwargs: None


async def _main(port: int) -> None:
    import tsx_lva  # noqa: WPS433

    tsx_lva._patch()  # pylint: disable=protected-access

    from linux_voice_assistant.models import Preferences, ServerState  # noqa: WPS433
    from linux_voice_assistant.satellite import VoiceSatelliteProtocol  # noqa: WPS433
    from linux_voice_assistant import zeroconf as lva_zeroconf  # noqa: WPS433

    tmp = Path(tempfile.mkdtemp(prefix="tsx-lva-harness-"))
    stop_word = types.SimpleNamespace(is_active=False, id="stop", wake_word="stop")
    available, wake_words, active = {}, {}, set()
    if os.environ.get("TSX_HARNESS_WAKEWORDS"):
        from linux_voice_assistant import wake_word  # noqa: WPS433

        stock = Path(wake_word.__file__).parent.parent / "wakewords"
        dirs = [stock, Path(os.environ["TSX_VOICE_WAKEWORDS"]), stock / "openWakeWord"]
        available = wake_word.find_available_wake_words(dirs, "stop")
        wake_words, active, _used = wake_word.load_wake_models(available, [], "okay_nabu")
        print(f"harness: {len(available)} wake words, active {sorted(active)}", flush=True)
    state = ServerState(
        name="lva-02aabbccddee",  # what LVA's __main__ passes; tsx_lva's patch must replace it
        friendly_name="hostname-fallback",
        mac_address="02:aa:bb:cc:dd:ee",
        ip_address="127.0.0.1",
        network_interface="lo",
        version="test",
        esphome_version="test",
        audio_queue=Queue(),
        entities=[],
        available_wake_words=available,
        wake_words=wake_words,
        active_wake_words=set(active),
        stop_word=stop_word,
        music_player=_NullPlayer(),
        tts_player=_NullPlayer(),
        wakeup_sound="", start_listening_sound="", processing_sound="",
        timer_finished_sound="", mute_sound="", unmute_sound="",
        button_double_press_sound="", button_triple_press_sound="", button_long_press_sound="",
        preferences=Preferences(),
        preferences_path=tmp / "preferences.json",
        download_dir=tmp,
    )
    print(f"harness: ServerState name={state.name!r} friendly_name={state.friendly_name!r}", flush=True)

    # the mDNS record LVA would register (not actually announced here)
    info = lva_zeroconf.AsyncServiceInfo(
        "_esphomelib._tcp.local.", f"{state.name}._esphomelib._tcp.local.",
        addresses=[bytes((127, 0, 0, 1))], port=port, properties={"mac": state.mac_address},
        server=f"{state.name}.local.")
    txt = {k.decode(): (v.decode() if v is not None else None) for k, v in info.properties.items()}
    print(f"harness: mDNS TXT {sorted(txt.items())}", flush=True)

    loop = asyncio.get_running_loop()
    await loop.create_server(lambda: VoiceSatelliteProtocol(state), host="127.0.0.1", port=port)
    print(f"harness: listening on 127.0.0.1:{port}", flush=True)
    await asyncio.Future()


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    os.environ.setdefault("TSX_VOICE_WAKE", "local")
    os.environ.setdefault("TSX_VOICE_KEEP_OUTPUT_OPEN", "1")
    _stub_wakeword_modules()
    asyncio.run(_main(int(sys.argv[1])))


if __name__ == "__main__":
    main()
