# Wake words

The voice satellite of the panel listens for a wake word on the panel. The panel has built-in wake words, and you can add your own wake word models. Home Assistant shows all of them in the wake word select of the panel device.

The satellite runs when `VOICE=on`. In push-to-talk mode (`WAKE=ptt` in `/etc/tsx/voice.conf`), the panel lists the wake words but does not listen for them.

## Built-in wake words

| Engine | Names |
|---|---|
| microWakeWord | `okay_nabu`, `hey_jarvis`, `hey_mycroft`, `alexa`, `hey_home_assistant`, `okay_computer`, `hey_luna`, `hey_morgan`, `choo_choo_homie` |
| openWakeWord | `ok_nabu_v0.1`, `hey_jarvis_v0.1`, `hey_mycroft_v0.1`, `alexa_v0.1`, `hey_rhasspy_v0.1`. Home Assistant shows them with "(OWW)". |

An openWakeWord model uses much more CPU than a microWakeWord model. Use microWakeWord when you can.

`WAKE_WORD` in `panel.conf` is the default wake word. The default value is `okay_nabu`. The satellite uses `WAKE_WORD` when it has no saved choice, and when the active wake word is gone. The wake word select in Home Assistant sets the active wake word. The satellite keeps that choice over a restart.

## Add a custom wake word

### Get a model

A model has two files with the same name: `<name>.json` and `<name>.tflite`. Use one of these sources:

- **microWakeWord** (recommended). Train a model with the training notebook of the [microWakeWord project](https://github.com/kahrendt/microWakeWord) (`notebooks/basic_training_notebook.ipynb`). The models for ESPHome voice devices also work, for example the models in [esphome/micro-wake-word-models](https://github.com/esphome/micro-wake-word-models) (`models/v2`). These models come with their `.json` file.
- **openWakeWord**. Train a model with the training notebook of the [openWakeWord project](https://github.com/dscripka/openWakeWord) (`notebooks/automatic_model_training.ipynb`). The panel needs the `.tflite` file, not the `.onnx` file. Write the `.json` file yourself (see below).

### Write the .json file

A model from the microWakeWord notebook or from an ESPHome model repository has its `.json` file. Change only `wake_word` if you want a different text in Home Assistant. Make sure that `model` is the name of the `.tflite` file.

The `.json` file of a microWakeWord model:

```json
{
  "type": "micro",
  "wake_word": "Hey Computer",
  "model": "hey_computer.tflite",
  "trained_languages": ["en"],
  "micro": {
    "probability_cutoff": 0.9,
    "sliding_window_size": 5
  }
}
```

The `.json` file of an openWakeWord model:

```json
{
  "type": "openWakeWord",
  "wake_word": "Hey Computer (OWW)",
  "model": "hey_computer.tflite",
  "openWakeWord": {
    "probability_cutoff": 0.7
  }
}
```

| Field | Required | Value |
|---|---|---|
| `type` | yes | `micro` or `openWakeWord` |
| `wake_word` | yes | The text in the Home Assistant select, 1 to 64 characters. Give each model a different text. |
| `model` | yes | `<name>.tflite`. The name must be the same as the name of the `.json` file. |
| `trained_languages` | no | A list of language codes, for example `["en"]` |
| `micro.probability_cutoff` | yes, for `micro` | The detection threshold, above 0 and at most 1 |
| `micro.sliding_window_size` | yes, for `micro` | A whole number from 1 to 1000. Keep the value of the model. |
| `openWakeWord.probability_cutoff` | no | The detection threshold, above 0 and at most 1. The default is 0.7. |

The name of the files can have letters, digits, `_`, `.` and `-` (at most 64 characters). To set the wake word with `WAKE_WORD`, use only `a`-`z`, `0`-`9` and `_` (at most 32 characters).

### Copy the model to the panel

1. Copy the two files to `/data/wakewords` on the panel:

   ```sh
   scp hey_computer.json hey_computer.tflite root@<panel-ip>:/data/wakewords/
   ```

2. Wait about 10 seconds. The satellite reads the folder again. Home Assistant connects to the panel again and gets the new list.
3. In Home Assistant, open the panel device. Select the new wake word in **Wake word**.

You do not restart anything. The panel entities are not available for a short time while Home Assistant connects again.

To make the new model the default wake word, run `tsx-config set WAKE_WORD hey_computer` and `tsx-config apply`.

### Remove a custom wake word

1. Remove the two files:

   ```sh
   ssh root@<panel-ip> rm /data/wakewords/hey_computer.json /data/wakewords/hey_computer.tflite
   ```

2. Wait about 10 seconds. Home Assistant gets the list without the model.

If the model was the active wake word, the satellite goes back to `WAKE_WORD`. If `WAKE_WORD` is not available, it goes back to `okay_nabu`. Home Assistant then connects two times. After the second connection, the select shows the new active wake word.

## Reference

### The folder

| Item | Value |
|---|---|
| Folder | `/data/wakewords`. It is on the data partition, so it stays after a package upgrade and after a reinstall that keeps `/data`. |
| Owner | `root`, mode 0755. The `tsx-voice` service makes the folder when it starts. |
| Files | Root writes the files. The satellite runs as the user `kiosk` and must be able to read them. `scp` gives mode 0644, which is correct. |
| Setting | `CUSTOM_WAKE_WORDS` in `/etc/tsx/voice.conf`. The default is `/data/wakewords`. An empty value turns custom models off. After a change, run `rc-service tsx-voice restart`. |

A custom model with the name of a built-in model replaces the built-in model. The name `stop` is not available: it is the stop word model.

### The checks

The satellite checks each model before it uses it. A bad model does not stop the satellite. The satellite skips the model and writes one line with the reason to `/var/log/tsx-voice.log`:

```text
wake word /data/wakewords/hey_computer.json skipped: the model file hey_computer.tflite is missing
```

| Check | A bad model |
|---|---|
| The `.json` file | Not valid JSON, more than 64 KiB, or not one JSON object |
| The fields | A field of the table above is missing or has a wrong value |
| The `.tflite` file | It is missing, it has more than 8 MiB, or it is not a TensorFlow Lite model |
| The load | The model did not load, or the satellite stopped while it loaded the model. The satellite skips the model until you copy the files again. |

### Updates

The satellite watches the folder. It waits until the folder has had no change for 3 seconds, and then it reads all models one time. A copy of a `.json` file and its `.tflite` file thus gives one update.

Home Assistant asks for the wake word list only when it connects to the panel. When the list changes, the satellite closes the connection to Home Assistant. Home Assistant connects again at once and gets the new list. The satellite waits until no conversation, timer or playback runs.

When only the files of a model change, and the list stays the same, the satellite loads the model again. Home Assistant does not connect again.

## Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| The new wake word is not in Home Assistant. | The model failed a check. | Read `/var/log/tsx-voice.log`. The line with "skipped" gives the reason. Correct the file and copy the two files again. |
| The new wake word is not in Home Assistant. | The panel plays a reply, a timer alarm or media. | The list comes when the playback stops. |
| The new wake word is not in Home Assistant. | `VOICE=off`. The satellite does not run. | Run `tsx-config set VOICE on` and `tsx-config apply`. |
| The log says "it did not load before". | The `.tflite` file is not a usable model. | Get the model again. Copy the two files again. |
| Two models show as one entry. | The two models have the same `wake_word` text. | Give each model a different text. |
| The wake word does not start a conversation, or it starts one too often. | The threshold does not fit the room. | Change the wake word sensitivity on the panel device page in Home Assistant. |
