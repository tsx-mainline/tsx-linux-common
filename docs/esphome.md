# ESPHome device

The panel is one ESPHome device in Home Assistant. The `VOICE` setting selects the service that serves the device:

| `VOICE` | Service | Code |
|---|---|---|
| `off` | `tsx-esphome` | `ha/voice/shim/tsx_panel/esphome_server.py` |
| `on` | `tsx-voice` | The voice satellite (linux-voice-assistant) with the shim `ha/voice/shim/tsx_lva`. It serves the panel entities and the satellite entities. |

## Device information

Both services send the same device information to Home Assistant. The device page does not change with `VOICE`. Only the voice feature flags differ (see "Voice features").

| Field | Value |
|---|---|
| `project_name` | `tsx-mainline.tsx-esphome`. Home Assistant shows the part before the dot as the manufacturer and the part after it as the model. |
| `manufacturer` | `Crestron (mainline Linux)` |
| `model` | The model of the panel. A board that gives only its family name gets the family name and `panel`, for example `xx60 panel`. A board that gives the model of the unit gets `Crestron` and the model. |
| `project_version`, `esphome_version` | The versions of linux-voice-assistant and of aioesphomeapi |

The code is `ha/voice/shim/tsx_panel/deviceinfo.py`. `tsx-esphome` and the shim `tsx_lva` both call it. The test is `tests/esphome-deviceinfo-check.py`. The device name (`naming.py`) and the Bluetooth proxy fields (`bluetooth.py`) also come from one module for both services.

## Voice features

A panel with a microphone announces the voice feature of the satellite in both modes. The device information has `voice_assistant_feature_flags` set to `VOICE_ASSISTANT`. A change of `VOICE` does not change this value. The announcement is needed because Home Assistant makes the voice selects only when it sets up the config entry. It makes them only if the device announces the voice feature at that time. A later connection does not add them. A change of `VOICE` therefore needs no reload of the config entry.

With `VOICE=off`, Home Assistant shows these entities:

- The assist satellite. It stays idle.
- The Assistant, Assistant 2 and Finished speaking detection selects.
- The Wake word and Wake word 2 selects. They are unavailable, because the device sends no wake word list.

With `VOICE=on`, the satellite sends the wake word list when Home Assistant connects. The wake word selects then show the list. The satellite also has its media player and its mute, sensitivity and thinking sound controls.

With `VOICE=off`, the device does not offer the features `ANNOUNCE`, `START_CONVERSATION` and `TIMERS`. If it did, Home Assistant would wait up to 5 minutes for the answer to an announcement, and the device would send no answer.

A panel without a microphone (`MIC=no` in `/run/tsx/hw.conf`) announces no voice feature and has no voice entities. The code is `voice_feature_flags` in `ha/voice/shim/tsx_panel/esphome_server.py`. The test is `tests/esphome-voiceflags-check.py`.

If Home Assistant set up the config entry while the panel announced no voice feature, the entry has no voice selects. Reload the ESPHome config entry once. Later changes of `VOICE` need no reload.

## Entity keys

Each entity has a fixed key. The key is the 32-bit FNV-1a hash of a fixed text:

| Entities | Text |
|---|---|
| The panel entities | `tsx:<object id>` |
| The LED bar actions | `tsx:action:<name>` |
| The satellite entities | `lva:<object id>` |

An entity has the same key with `VOICE` on or off. The order of the entities does not change a key. The optional entities (LED bar, sensors, the entities of plugins) do not change the keys of other entities. No key is below `0x10000`. When two texts give the same hash, the second entity gets the hash of `<text>#1`, and the log shows a warning. The code is `ha/voice/shim/tsx_panel/keys.py`.

### Add an entity

- To add an entity, give it a new object id.
- Do not change the object id of an existing entity. Its key then changes, and Home Assistant sees a new entity. The entity loses its settings in Home Assistant, for example its name and its area.
- Run `tests/test-shim-keys.sh`. The test fails when two known entities have the same key.

## Plugins

A board can add entities and API messages to the device. The board package ships one Python file in `/usr/local/share/tsx/esphome.d`. A board with a part that has no shared code, for example a camera, ships the code for it there. Both services load the same files, so the device is the same with `VOICE` on or off. The code is `ha/voice/shim/tsx_panel/plugins.py`.

Each service loads each file once, when it starts. It loads the files in name order. A file with a name that starts with `_` or `.` is not a plugin.

### What a plugin file defines

Every name is optional. A missing name means "nothing to do".

| Name | Meaning |
|---|---|
| `entities(server, key_for)` | Returns a list of entities. Use the classes of `tsx_panel.entities`, or an `ESPHomeEntity` of your own. `key_for(object_id)` gives the fixed key of an entity. `key_for.action(name)` gives the key of a user-defined action. |
| `handle_message(conn, msg)` | Called for each API message of a client, after the Bluetooth proxy. Return `True` when the plugin took the message. Take only a message that no other code handles, for example the request for an entity type that only the plugin knows. To answer, call `conn.send_messages(msgs)`. |
| `connection_lost(conn)` | Called when a client connection closes. |

The service adds the entities to the entity list, after its own entities. Then it handles them like its own entities: the entity list, the state subscription and the commands. In each poll, it calls `poll()` of each plugin entity that has this method. An entity sends its state when its `_state` attribute changed. The classes `SensorEntity`, `TextSensorEntity` and `SwitchEntity` of `tsx_panel.entities` work this way.

A plugin can use `tsx_panel.entities`, `tsx_panel.hw` (the hardware facts of `hw.conf`) and `tsx_panel.keys`.

### Rules for a plugin

- Give each entity a new object id. An object id of the device, or of another plugin, gives the same key twice.
- Do not change the object id of an entity later. Its key changes, and Home Assistant sees a new entity (see "Entity keys").
- Import `tsx_panel` with absolute names, for example `from tsx_panel import hw`. The loader runs the file under the module name `tsx_esphome_plugin_<file name>`, so a relative import fails. The test `if __name__ == "__main__"` is false under the loader. A command line in the plugin file needs `PYTHONPATH` with the folder of `tsx_panel`.
- Keep `handle_message` short. It runs in the event loop of the service. Start a thread for slow work.
- Do not read `panel.conf`. The voice satellite runs as user `kiosk` and cannot read it. Use a file in `/run/tsx`, which `tsx-config apply` writes (see [Plugin folders](layout.md#plugin-folders)).

### Trust and errors

Root must own the folder and each file. The group and others must not be able to write them. The service does not load a file that fails this check, and it does not load a link. The voice satellite runs as user `kiosk`. A file that this user could write would run in every start of the satellite and, as root, in every start of `tsx-esphome`.

A file that does not load gives one log line, and the device starts without it. An error in a function of a plugin gives one log line with the details. The next errors of this function give one line each, without the details. The device keeps running, and the next plugin runs.

### Tests

The fake plugin of the made-up board is `tests/boards/fake/esphome.d/fakeent.py`. It has an entity for the entity list, a button and a text sensor with a state getter. It also handles an API message that no other code handles. `tests/test-shim-plugins.sh` loads it into both services with small stand-ins for the libraries. `tests/test-esphome.sh` loads it into both real services and connects with the client library of Home Assistant.

| Test hook | Meaning |
|---|---|
| `TSX_ESPHOME_PLUGIN_DIR` | The folder of the plugins. The default is `/usr/local/share/tsx/esphome.d`. |
| `TSX_PLUGIN_OWNER_UID` | The user id that must own the folder and the files. The default is 0. A test sets the id of its own user. |

