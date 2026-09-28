"""TSX panel glue around linux-voice-assistant .

Runs linux_voice_assistant.__main__.run() after a few in-process adaptations,
all driven by environment variables that /etc/init.d/tsx-voice sets from
/etc/tsx/voice.conf:

  TSX_VOICE_PTT=/run/tsx/voice/ptt   FIFO; each line is a command:
        ptt              push-to-talk toggle (idle: start listening, busy: stop)
        start_listening, stop_pipeline, mute_mic, unmute_mic, volume_up,
        volume_down, stop_timer_ringing, ... (any peripheral API command)
  TSX_VOICE_HOOK=/usr/local/bin/tsx-voice-hook
        run with detection|listen|think|speak|error|done on assistant events
        (ducking of the "Media" softvol, LED bar, /run/tsx/voice/voice.state)
  TSX_VOICE_WAKE=ptt|local
        ptt: no on-device wake word or stop word inference (saves CPU; the
        models are still loaded so HA's wake word select keeps working)
  TSX_VOICE_KEEP_OUTPUT_OPEN=0|1
        1 = upstream behaviour (mpv plays silence between sounds, the output
        stream stays open, SPK_EN and dmix stay active all the time)

When HA_TRANSPORT is esphome or both (panel.conf, tsx-config; default
esphome), this also appends the panel's own Home Assistant entities (LED
bar, key LEDs, screen, backlight, kiosk URL, front-key events, sensors --
see rootfs/voice/shim/tsx_panel/) into this SAME process's ESPHome device,
so Home Assistant discovers exactly one device whether or not voice is on
(PLAN.md section 18; the standalone tsx-esphome serves the same entities
when VOICE=off instead -- see docs/ha.md "One Home Assistant device"). This
is why the plugin patches VoiceSatelliteProtocol rather than starting a
second ESPHome server: a second TCP listener on the same port would just
fail to bind, and a different port would be a second, confusing device.
"""

import asyncio
import json
import logging
import os
import queue
import subprocess
import sys
import threading
import time

_LOGGER = logging.getLogger("tsx_lva")

_HOOK_EVENTS = {
    "wake_word_detected": "detection",
    "listening": "listen",
    "thinking": "think",
    "tts_speaking": "speak",
    "pipeline_error": "error",
    "idle": "done",
    "disconnected": "done",
}


class _Glue:
    def __init__(self):
        self.api = None  # PeripheralAPIServer
        self.hook = os.environ.get("TSX_VOICE_HOOK", "")
        self._hooks: "queue.Queue[str]" = queue.Queue()
        self.last_hook = None

    # --- hooks (sequential, off the event loop) ---------------------------
    def hook_event(self, name):
        arg = _HOOK_EVENTS.get(name)
        if not arg or not self.hook:
            return
        if arg == self.last_hook and arg in ("done", "listen"):
            return
        self.last_hook = arg
        self._hooks.put(arg)

    def _hook_worker(self):
        while True:
            arg = self._hooks.get()
            try:
                subprocess.run([self.hook, arg], timeout=15, stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            except Exception as err:  # noqa: BLE001
                _LOGGER.warning("hook %s %s failed: %s", self.hook, arg, err)

    # --- push-to-talk FIFO -------------------------------------------------
    def _command(self, line):
        api = self.api
        if api is None or api._loop is None:  # pylint: disable=protected-access
            _LOGGER.warning("command %r ignored: peripheral API not running", line)
            return
        state = api._state  # pylint: disable=protected-access
        if line == "ptt":
            sat = state.satellite if state is not None else None
            if sat is None:
                _LOGGER.warning("push-to-talk ignored: Home Assistant not connected")
                return
            busy = getattr(sat, "_pipeline_active", False) or getattr(sat, "_timer_finished", False)
            line = "stop_pipeline" if busy else "start_listening"
            if getattr(sat, "_timer_finished", False):
                line = "stop_timer_ringing"
        _LOGGER.info("FIFO command: %s", line)
        asyncio.run_coroutine_threadsafe(
            api._dispatch_command(json.dumps({"command": line})), api._loop)  # pylint: disable=protected-access

    def _fifo_worker(self, path):
        while True:
            try:
                with open(path, "r", encoding="utf-8") as fifo:  # blocks until a writer opens
                    for line in fifo:
                        line = line.strip()
                        if line:
                            self._command(line)
            except Exception as err:  # noqa: BLE001
                _LOGGER.warning("FIFO %s: %s", path, err)
                threading.Event().wait(2.0)

    def start_threads(self):
        if self.hook:
            threading.Thread(target=self._hook_worker, name="tsx-hook", daemon=True).start()
        fifo = os.environ.get("TSX_VOICE_PTT", "")
        if fifo:
            threading.Thread(target=self._fifo_worker, args=(fifo,), name="tsx-ptt", daemon=True).start()


GLUE = _Glue()


def _ha_transport():
    """esphome|mqtt|both, from the world-readable override tsx-config apply
    writes (see rootfs/overlay/usr/local/sbin/tsx-config "HA_TRANSPORT"):
    this process runs as kiosk:audio and cannot read $TSX_CONF (mode 600,
    it carries HA_TOKEN/MQTT_PASSWORD) directly. Test override:
    TSX_HA_TRANSPORT.
    """
    override = os.environ.get("TSX_HA_TRANSPORT")
    if override:
        return override
    path = os.environ.get("TSX_ESPHOME_RUN_CONF", "/run/tsx/esphome.conf")
    try:
        with open(path, "r", encoding="utf-8") as fobj:
            for line in fobj:
                line = line.strip()
                if line.startswith("TRANSPORT="):
                    return line.split("=", 1)[1].strip('"')
    except OSError:
        pass
    return "esphome"


def _patch_panel():
    """Append the panel's own entities into the voice satellite's ESPHome
    device (see the module docstring). No-op when HA_TRANSPORT=mqtt (the
    panel opted out of ESPHome for everything but the voice satellite's own
    mandatory entities, which are not ours to remove).
    """
    if _ha_transport() == "mqtt":
        _LOGGER.info("tsx_panel: HA_TRANSPORT=mqtt, not adding panel entities")
        return

    from aioesphomeapi.api_pb2 import (  # noqa: WPS433
        ButtonCommandRequest,
        TextCommandRequest,
    )
    from linux_voice_assistant.satellite import VoiceSatelliteProtocol  # noqa: WPS433
    from tsx_panel import device as panel_device  # noqa: WPS433
    from tsx_panel.backend import PanelBackend  # noqa: WPS433

    extra_commands = (ButtonCommandRequest, TextCommandRequest)
    poll_started = threading.Event()

    def _poll_loop(state, device):
        while True:
            try:
                panel_device.poll(device, state.broadcast)
            except Exception:  # noqa: BLE001 - one bad read must not kill the loop
                _LOGGER.warning("tsx_panel: poll failed", exc_info=True)
            time.sleep(panel_device.POLL_INTERVAL)

    orig_init = VoiceSatelliteProtocol.__init__

    def init(self, state):
        orig_init(self, state)
        # Built once per ServerState (survives HA reconnects, like LVA's own
        # pending_lights/pending_button): the first connection builds it and
        # starts the poll thread, every later connection just reuses it.
        device = getattr(state, "_tsx_panel_device", None)
        if device is None:
            backend = PanelBackend()
            device = panel_device.build_entities(self, backend, key_base=len(state.entities))
            state._tsx_panel_device = device  # pylint: disable=protected-access
            state.entities.extend(device.entities)
            _LOGGER.info("tsx_panel: added %d panel entities to the voice satellite's device", len(device.entities))
            if not poll_started.is_set():
                poll_started.set()
                threading.Thread(target=_poll_loop, args=(state, device), name="tsx-panel-poll", daemon=True).start()

    VoiceSatelliteProtocol.__init__ = init

    # satellite.py's own handle_message forwards ListEntitiesRequest,
    # SubscribeHomeAssistantStatesRequest, MediaPlayerCommandRequest,
    # SwitchCommandRequest, NumberCommandRequest, SelectCommandRequest and
    # LightCommandRequest to state.entities, but not Button/TextCommandRequest
    # (linux-voice-assistant 1.1.15 has no Button/Text entities of its own) --
    # see tsx_panel/entities.py's module docstring. Add the two we need.
    orig_handle = VoiceSatelliteProtocol.handle_message

    def handle_message(self, msg):
        if isinstance(msg, extra_commands):
            for entity in self.state.entities:
                yield from entity.handle_message(msg)
            return
        yield from orig_handle(self, msg)

    VoiceSatelliteProtocol.handle_message = handle_message


def _patch():
    # HA_ALLOW_FROM (panel.conf): the ESPHome API has no encryption or
    # password, so this is enforced unconditionally, even when
    # HA_TRANSPORT=mqtt opted the panel entities out -- the satellite's own
    # entities (assist_satellite, its media player, ...) are exposed on this
    # same port regardless of HA_TRANSPORT. See tsx_panel/security.py.
    from tsx_panel import security  # noqa: WPS433

    security.enforce()

    from linux_voice_assistant import peripheral_api  # noqa: WPS433

    cls = peripheral_api.PeripheralAPIServer
    orig_start, orig_emit = cls.start, cls.emit_event

    async def start(self):
        GLUE.api = self
        await orig_start(self)
        if self._loop is None:  # pylint: disable=protected-access
            # websockets missing: still let the FIFO dispatch commands
            self._loop = asyncio.get_running_loop()  # pylint: disable=protected-access

    async def emit_event(self, event, data=None):
        GLUE.hook_event(getattr(event, "value", str(event)))
        await orig_emit(self, event, data)

    cls.start, cls.emit_event = start, emit_event

    if os.environ.get("TSX_VOICE_WAKE", "local") == "ptt":
        import pymicro_wakeword  # noqa: WPS433
        import pyopen_wakeword  # noqa: WPS433

        # no features -> no inference; wake word and stop word never fire
        pymicro_wakeword.MicroWakeWordFeatures.process_streaming = lambda self, audio: []
        pyopen_wakeword.OpenWakeWordFeatures.process_streaming = lambda self, audio: []
        # logging is not configured yet (LVA does it in main): print
        print("tsx_lva: push-to-talk only: on-device wake word disabled", file=sys.stderr, flush=True)

    if os.environ.get("TSX_VOICE_KEEP_OUTPUT_OPEN", "0") != "1":
        from linux_voice_assistant.player import libmpv  # noqa: WPS433

        orig_init = libmpv.LibMpvPlayer.__init__

        def init(self, *args, **kwargs):
            orig_init(self, *args, **kwargs)
            self._mpv["audio-stream-silence"] = False  # pylint: disable=protected-access
            self._mpv["audio-buffer"] = float(os.environ.get("TSX_VOICE_AUDIO_BUFFER", "0.2"))  # pylint: disable=protected-access

        libmpv.LibMpvPlayer.__init__ = init

    try:
        _patch_panel()
    except Exception:  # noqa: BLE001 - a broken panel plugin must not break voice
        _LOGGER.warning("tsx_panel: could not attach panel entities", exc_info=True)


def main():
    _patch()
    GLUE.start_threads()
    from linux_voice_assistant.__main__ import run  # noqa: WPS433

    run()
