# LED bar

The USB RGB LED bar has 16 LEDs, 8 on each side. The package `tsx-ledbar` sets its colors, effects and LEDs, and keeps the bar working. This page describes the tools, the settings, the recovery from bootloader mode, the effects, the 16 LEDs and the LED map.

The bar is one USB device (`14be:001b`) with an STM32 controller. The stock firmware shows one color on all LEDs. The optional firmware TSX-LEDBAR (package `tsx-ledbar-fw`) adds effects, control of each LED and LED maps. Only the TSW-1060-LB bar is tested on hardware. Other bar models are not tested.

## Parts

| Part | Purpose |
|---|---|
| `/usr/local/bin/tsx-ledbar` | The tool. It sets colors, effects and LEDs, and sends lines to the bar console. |
| `/usr/local/sbin/tsx-ledbard` | The service program. It checks the bar, recovers it from bootloader mode and sends the settings. |
| `/etc/init.d/tsx-ledbar` | The OpenRC service that runs `tsx-ledbard`. |
| `/etc/tsx/ledbar.conf` | The settings. Run `rc-service tsx-ledbar restart` after a change. |
| `/run/tsx/ledbar.state` | The wanted color, the pattern and the effect. |
| `/run/tsx/ledbar.fw` | The firmware lines of the bar, for users without root. |
| `/run/tsx/ledbar.usb` | One word that tells whether a bar is attached: `app` or `bootloader`. |
| `/var/log/tsx-ledbar.log` | The log of the service. |

`tsx-ledbar` has two back ends:

- With the kernel driver `leds-crestron-stm32`, it uses the LED class device `/sys/class/leds/tsx:rgb:bar`.
- Without the driver, it uses libusb and claims USB interface 1 of the bar.

The option `--usb` forces libusb and detaches the kernel driver while the tool runs. The bar console (USB interface 0) always uses libusb. No kernel driver binds interface 0, so the driver keeps interface 1.

## Commands

| Command | Effect |
|---|---|
| `tsx-ledbar set R G B` | Set the color. Each level is 0 to 100. |
| `tsx-ledbar on` | Show the last color that was not black. Else show `BOOT_COLOR`. |
| `tsx-ledbar off` | Show black. |
| `tsx-ledbar boot` | Set `BOOT_COLOR`. |
| `tsx-ledbar get` | Print the wanted, last and output color, the running effect and the LED pattern. |
| `tsx-ledbar apply` | Send the wanted color, the recorded pattern and the recorded effect again. |
| `tsx-ledbar fw` | Print the firmware name, `effects yes` or `effects no`, and `leds yes` or `leds no`. |
| `tsx-ledbar console LINE [MS]` | Send one line to the bar console and print the answer. |
| `tsx-ledbar info` | Print the back end and the device details. |
| `tsx-ledbar raw HEX...` | Send one Cresnet packet. |

The option `-n` prints the packets and sends nothing. `tsx-ledbar` without a command prints all commands.

A new color (`set`, `on`, `off`, `boot`) ends the running effect and the LED pattern. The screen state never changes the bar.

## Settings

`/etc/tsx/ledbar.conf` holds these keys:

| Key | Meaning | Default |
|---|---|---|
| `BOOT_COLOR` | The color that the service sets when it first finds the bar after its start: R G B, each 0 to 100. | `0 0 0` |
| `FX_SMOOTH` | The time in ms to ramp each new color (0 to 60000). It needs TSX-LEDBAR. | Empty: the firmware default (0, at once). |
| `FX_CAP` | The power cap of the three colors, in percent of one full color (10 to 150). It needs TSX-LEDBAR. | Empty: the firmware default (110). |
| `LEDMAP` | The LED map. It needs TSX-LEDBAR 0.1.5 or later. See "LED map". | Empty: the map of the board. |

The keys `BLANK` and `BLANK_DIM` of an old file have no effect. The service logs one line when it finds them.

## When Home Assistant shows the LED bar

Home Assistant shows the LED bar light, its effects and its actions only while a bar with its application is attached. The light appears when you plug in the bar. It goes when you remove the bar.

One file tells whether a bar is attached: `/run/tsx/ledbar.usb`. The service `tsx-ledbard` writes it. It has one word:

| Content | Meaning | LED bar light |
|---|---|---|
| `app` | The bar runs its application (USB `14be:001b`). The check and the settings are done. | Yes |
| `bootloader` | The bar is in recovery (USB `14be:001a`). It is attached and has no light. | No |
| No file | No bar is attached, or the service is not running. | No |

- The daemon writes `app` after the check, the settings and the firmware file. A reader that sees `app` can also read `/run/tsx/ledbar.fw`.
- The daemon removes the file `TSX_LEDBAR_GONE` seconds after the bar goes (default 5). A short USB reset of the bar does not remove the light. During a restart of the controller by the daemon itself, the file stays unchanged.
- At the same time, and just after it, the daemon removes `/run/tsx/ledbar.fw`. So the entity list of the ESPHome device changes once when the bar goes. It does not first lose the effects and the actions of the light and then the light.
- The daemon removes a file of an earlier run when it starts, and it removes the file when it stops. `tsx-ledbard check` does not change the file.
- A USB device with `authorized` 0 in sysfs does not count. The kernel does not use such a device. Use this to remove a bar without a person: `echo 0 > /sys/bus/usb/devices/<device>/authorized`. Write `1` to bring it back.
- A bar in the bootloader gives no light. The bar has no application then, and it shows nothing. The light comes back when the application runs again, for example after the recovery in "Bootloader mode".

`tsx-panelctl has ledbar` is the one question that all programs ask. The answer is yes when all of these are true:

1. The tool `tsx-ledbar` is installed.
2. `hw.conf` does not say `LEDBAR=no`.
3. `/run/tsx/ledbar.usb` says `app`.

The `tsx-hw` program of the board writes the facts of the panel to `/run/tsx/hw.conf`. The key `LEDBAR` is optional. `LEDBAR=no` is the hard off: the light stays away also when a bar is attached. A missing file, a missing key and `LEDBAR=yes` do not change the answer. The last `LEDBAR` line of the file counts. The environment variable `TSX_HW_CONF` names another file, for tests.

| Part | What it does when the bar comes or goes |
|---|---|
| `tsx-esphome` and the voice satellite | They change the entity list and ask Home Assistant to reconnect. See "LED bar entities" in `esphome.md`. |
| `tsx-mqtt` | It publishes the discovery topic of the LED bar light when the bar comes. It publishes an empty retained payload when the bar goes. It also clears the retained state topics of the light. |
| `tsx-voice-hook` | It sets the LED bar color only while `has ledbar` is yes. |

While the bar is off, `tsx-mqtt` publishes the brightness and the color of the last color that was not black. An `ON` command without a brightness or a color runs `tsx-ledbar on`, which shows this color again. The ESPHome light does the same. See "LED bar entities" in `esphome.md`.

Home Assistant sends the color and the brightness of the MQTT light as separate messages (`rgb/set`, `brightness/set`, then `set ON`), and the color is always at full level. `tsx-mqtt` waits 0.2 seconds for the messages that belong together. Then it sends one `ledbar set` command with the final color. So the bar never shows the color at full level before the brightness applies. An `OFF` or an effect command in the same wait replaces the pending color. The ESPHome light gets the state, the color and the brightness in one message, so it sends one command without a wait.

With the bar firmware TSX-LEDBAR, the MQTT light also has the effects of the bar. The list is the one of the ESPHome light, without `Pulse`. `Pulse` is a software effect of the ESPHome device, and `tsx-mqtt` has no such loop. The discovery topic has these effects:

| Effect | Needs | Command that `tsx-mqtt` sends |
|---|---|---|
| `None` | the firmware has effects | `tsx-panelctl send ledbar fx off` (only while an effect runs) |
| `Breathe`, `Blink`, `Rainbow` | `tsx-panelctl has ledbar-fx` | `fx breathe`, `fx blink`, `fx rainbow` with the color and the brightness of the light |
| `Chase`, `Fill`, `Spectrum` | `tsx-panelctl has ledbar-leds` | `fx chase`, `fx fill`, `fx spectrum` |

The effect topics are `<base>/ledbar/effect` (state) and `<base>/ledbar/effect/set` (command). While an effect runs, the light shows the color of the effect. `Rainbow` and `Spectrum` keep the last color of Home Assistant. The bar shows white for them. `tsx-mqtt` reads `/run/tsx/ledbar.fw` too. When the firmware changes, it publishes the discovery topic again with the new effect list. A bar with the stock firmware gets a light with no effects.

`tsx-mqtt` also follows `LEDBAR=no`. It publishes no LED bar state topic and ignores each LED bar command. It logs one line for each ignored command. The same holds for a panel without a bar.

Home Assistant removes an entity that the device does not list. A removed light also loses the name, the area and the settings that you gave it in Home Assistant. A bar that comes back gets the same entity again, with the same unique id. The entity key does not change.

## Start check

At power-up, the STM32 can fail to start its three LED driver chips. Then no color lights. When the bar appears, `tsx-ledbard` asks the bar console for the state of each chip (`tsx-ledbar console 'tlcoutmode red 0'`). If a chip did not start, the daemon restarts the STM32 (`tsx-ledbar console reboot`) and checks again, at most 3 times.

Then the daemon sends the settings of the firmware and sets the color. The color is `BOOT_COLOR` after the first start of the service. After a plug-in, it is the wanted color.

For a manual check, stop the service and run `tsx-ledbard check`. The command exits with 1 when the bar stays dark. It also exits with 1 when the bar is in bootloader mode.

## Bootloader mode

The bar controller can stop in its stock bootloader (USB `14be:001a`). It then runs no application, and the LEDs stay dark. An interrupted load can cause this. The start guard of TSX-LEDBAR can also cause it: after three failed starts in a row, the guard hands the bar to the bootloader.

`tsx-ledbard` looks for this state when the service starts and when the bar appears later. It loads an image with `tsx-ledbar-fw-install --recover`. The tool comes with the package `tsx-ledbar-fw`, together with the TSX-LEDBAR image and the flasher.

| Case | What the daemon does |
|---|---|
| The package is installed and `/data/tsx/ledbar-fw.installed` exists | Loads the TSX-LEDBAR image. |
| The package is installed, the file does not exist, and `/data/tsx/vendor/` has a stock image | Loads the newest stock image (`statussign_*.upg`). |
| The package is installed, the file does not exist, and there is no stock image | Loads the TSX-LEDBAR image. |
| The package is not installed | Logs one line. It tells you to run `apk add tsx-ledbar-fw` and to restart the service. |
| The package is installed, but its `tsx-ledbar-fw-install` has no `--recover-image` | Logs one line. It tells you to run `apk upgrade tsx-ledbar-fw` and to restart the service. |

- The marker file `/data/tsx/ledbar-fw.installed` shows that the panel is set up for TSX-LEDBAR. `tsx-ledbar-fw-install` writes it and `tsx-ledbar-fw-uninstall` removes it. A recovery does not change it.
- If no image exists, the daemon logs one line and does nothing else.
- The daemon tries once for each start of the service. It does not try again after a failed load. It also does not try again when the bar returns to the bootloader later. To try again, run `rc-service tsx-ledbar restart`. You can also load an image by hand with `tsx-ledbar-fw-install` or `tsx-ledbar-fw-uninstall`.
- The load does not stop the `tsx-ledbar` service. It restarts `tsx-esphome` and `tsx-voice` when they run, because these services read the firmware name of the bar only at start.
- The daemon never sends `TLCRESET` and never cuts the power of the bar.
- `/var/log/tsx-ledbar.log` shows a start line, the progress lines of the flasher and a result line.

## Effects

The firmware TSX-LEDBAR runs effects on the bar. `tsx-ledbar fw` prints `effects yes` for this firmware. With the stock firmware, `tsx-ledbar fx` refuses and everything else works.

| Command | Effect |
|---|---|
| `tsx-ledbar fx fade R G B MS` | Fade to the color in MS ms (0 to 600000). |
| `tsx-ledbar fx blink R G B ON OFF` | Blink: ON ms on, OFF ms off. |
| `tsx-ledbar fx breathe R G B MS` | Breathe, one breath in MS ms (100 to 600000). |
| `tsx-ledbar fx rainbow MS [LEVEL]` | Cycle the hue in MS ms at LEVEL (0 to 100, default 100). |
| `tsx-ledbar fx smooth MS` | Ramp each new color over MS ms (0 to 60000). |
| `tsx-ledbar fx cap PERCENT` | Set the power cap of the three colors (10 to 150, default 110). |
| `tsx-ledbar fx off` | End the effect and show the wanted color. |
| `tsx-ledbar fx` | Print the running effect. |

- The tool sends effects as lines on the bar console. The kernel driver keeps interface 1.
- An effect does not change the wanted color. `fx off` shows the wanted color again, also after `fade`. For a smooth change that stays, run `tsx-ledbar fx smooth MS` once and then `tsx-ledbar set R G B`.
- `tsx-ledbar get` shows the wanted color, the running effect and the LED pattern. `/run/tsx/ledbar.state` records the effect (`fx ...`).
- `tsx-ledbar apply` sends the recorded color, pattern and effect again. So they come back after a restart of the bar.
- `FX_SMOOTH` and `FX_CAP` in `ledbar.conf` set the ramp and the cap. `tsx-ledbard` sends them each time the bar appears.

## The 16 LEDs

TSX-LEDBAR 0.1.3 or later sets each of the 16 LEDs and has zone effects. `tsx-ledbar fw` prints `leds yes` when the answer to `CAPS` has the word `leds16`. Without `leds yes` (for example with the stock firmware), these commands refuse and change nothing.

A LED is `R1` to `R8` (right side) or `L1` to `L8` (left side), from top to bottom. The index `0` to `15` is `R1` to `R8`, then `L1` to `L8`. `LEDS` is one LED, a range (`R1-R4`, `8-11`), a side (`R` or `L`) or `ALL`.

| Command | Effect |
|---|---|
| `tsx-ledbar led LEDS R G B` | Set LEDs of the pattern (levels 0 to 100). |
| `tsx-ledbar side R\|L R G B` | Set one side of the pattern. |
| `tsx-ledbar clear` | Drop the pattern and show the wanted color. |
| `tsx-ledbar fx chase R G B MS` | A dot runs down both sides, one run in MS ms (100 to 600000). |
| `tsx-ledbar fx fill R G B PERCENT` | A level bar from the bottom up, PERCENT of the height. |
| `tsx-ledbar fx spectrum MS [LEVEL] [ring\|rows]` | The hue circle, one cycle in MS ms. `ring` (the firmware default) runs around the bar. `rows` runs along each side. |
| `tsx-ledbar fx split R G B R G B` | The first color on the right side, the second on the left. |

- The first `led` or `side` copies the wanted color into all 16 LEDs, then changes the LEDs that you give. `/run/tsx/ledbar.state` records the pattern (`pattern` and 48 levels, or `pattern none`).
- A LED command ends the effect. An effect on top of the pattern keeps the pattern, and `fx off` goes back to it. A new color ends both.
- `tsx-ledbar apply` sends the color, then the pattern, then the effect.

## The firmware file

The `CAPS` query needs root, because only root can open the USB device of the bar. So `tsx-ledbard` writes the answer to `/run/tsx/ledbar.fw` (mode 644) after each plug-in and each start of the bar. The file has the lines of `tsx-ledbar fw` and the line `caps` with the words of the answer to `CAPS`. The line is `caps none` when the bar has no `CAPS`.

`tsx-panelctl has ledbar-fx` and `has ledbar-leds` read this file. So the voice satellite (user `kiosk`) gets the same answer as root. Without the file, `tsx-panelctl` runs `tsx-ledbar fw`, which gives the full answer only to root.

The daemon removes the file when the bar goes away, when the bar is in bootloader mode and when the service stops. `tsx-ledbard check` does not change the file.

## LED map

A LED map gives the position of each LED on the bar. The bar cannot tell its model, so the panel tells the bar which map to use. The default map of TSX-LEDBAR 0.1.5 and later is the map of the TSW-1060-LB bar. Another bar model can have a different map.

After each plug-in and each start of the bar, `tsx-ledbard` sends the map before the first color. It sends the map only when the answer to `CAPS` has the word `ledmap`. The map comes from these sources, first match first:

| Source | `tsx-ledbard` sends |
|---|---|
| `LEDMAP` in `ledbar.conf` is a map name, for example `outputs` | `LEDMAP NAME PANEL` |
| `LEDMAP` is `default` | `LEDMAP DEFAULT` |
| `LEDMAP` is empty, and the board function `tsx_board_ledbar_map` prints a map name | `LEDMAP NAME PANEL` |
| `LEDMAP` is empty, and the board function prints nothing or does not exist | `LEDMAP DEFAULT`: the firmware default map |

- The board file defines `tsx_board_ledbar_map MODEL`. `MODEL` is the panel model and can be empty. The function prints the name of a map, or nothing when no bar is tested on the model. A name has only letters, digits and `-`.
- `tsx-ledbard` runs the board file in a subshell, so the board file cannot change the daemon. The daemon uses the first line of the answer and drops other characters.
- The panel model comes from `/run/tsx/model`. `tsx-hostname` writes it at boot from `tsx_board_model` of the board file. The file can be missing, and then the argument is empty.
- The map `outputs` lights LED n on output n. Use it to find the map of a bar model that has no map. The `tsx-ledbar-fw` docs give the steps.
- The firmware does not save the map. After `rc-service tsx-ledbar restart`, the daemon sends it again.
- `tsx-ledbar console LEDMAP` shows the map in use, for example `variant 1 map TSW-1060-LB panel`. The last word is the source: `default`, `panel` (from the daemon) or `console` (from a user). The variant value is for information only.
- `/var/log/tsx-ledbar.log` has one line for each map that the daemon sends, with the answer of the bar. A name that the bar does not have gives one log line, and the bar keeps its map.
- The daemon sends no `LEDMAP` to the stock firmware or to a TSX-LEDBAR version without `ledmap`. A `LEDMAP` key then gives one log line.

This example is a board function for a family with one tested bar:

```sh
tsx_board_ledbar_map() {
	case ${1:-} in
	TSW-1060|TSW-1060-*) echo TSW-1060-LB;;
	esac
}
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| The log says `LED bar not found yet (USB 14be:001b)` | The bar is not plugged in. | Plug in the bar. |
| The bar stays dark. The log says `LED drivers did not start after 3 restarts`. | The LED driver chips do not start. | Unplug the bar and plug it in again. |
| The bar stays dark. The log says `bootloader mode (USB 14be:001a)`. | The controller runs the bootloader only. | Follow the log line. See "Bootloader mode". |
| Home Assistant shows no LED bar light. | No bar with its application is attached, or `LEDBAR=no`. | Run `cat /run/tsx/ledbar.usb` and `tsx-panelctl has ledbar; echo $?`. The file must say `app`. |
| `tsx-ledbar fx` refuses | The bar has the stock firmware. | Load the TSX-LEDBAR firmware with the package `tsx-ledbar-fw`. |
| The log says `LEDMAP=... needs the LED bar firmware TSX-LEDBAR 0.1.5 or later` | The bar firmware has no LED maps. | Upgrade the package `tsx-ledbar-fw`, or empty the `LEDMAP` key. |
| The log says `the bar has no map NAME` | The firmware has no map with this name. | Use a name from the `maps` list in the log line. The bar keeps its map. |

## Tests

- `tests/ledbar-host-test.sh` builds `tsx-ledbar` without libusb. It checks the packets, the kernel back end, the state file, the effects and the 16 LEDs.
- `tests/test-ledbard.sh` runs `tsx-ledbard` against a fake bar, a fake console and the made-up test board. It also checks the file `ledbar.usb`: a bar at the start, a plug-in, a removal, a short reset, the bootloader and a stop of the service.
- `tests/test-panelctl.sh` checks `has ledbar` with each form of the file and of `LEDBAR`.
- `tests/mqtt-dry.sh` checks the LED bar light of `tsx-mqtt` with the real `tsx-panelctl`. `tests/mqtt-ledbar-live.sh` runs `tsx-mqtt` and changes the file while it runs. It also sends a color, a brightness and `ON` to the running `tsx-mqtt` and counts the commands that reach the bar.
- `tests/test-shim-ledbar.sh` and `tests/test-esphome-ledbar.sh` check the entities of the ESPHome device, also while the bar comes and goes.

The libusb back end needs a bar.
