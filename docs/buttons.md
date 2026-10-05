# Front keys

Some panels have keys on the front. The service `tsx-buttons` reads the keys and controls their LEDs. This page tells how to add the keys of a board and how to bind an action to a key. It also tells what a key press does.

## What a key press does

A press does these things and no others, unless you bind an action to the key:

- It fires the event `tsx_button` in Home Assistant. The data has the panel name, the key name, the press (`short` or `long`) and the key code.
- It writes the line `last NAME PRESS TIME` to `/run/tsx/buttons.state`. The ESPHome event entity of the key and the MQTT event of the key read this line.

A press on a blank screen only wakes the screen. `tsx-idled` grabs the input devices while the screen is blank, so `tsx-buttons` sees no press.

Home Assistant controls the key LEDs. The light *Key LEDs* sets their level. The number *Key LEDs screen-off level* sets their level while the screen is blank (ESPHome only).

## Configuration

`tsx-buttons` reads three files in this order. A later file replaces a setting of an earlier file.

| File | Owner | Content |
|---|---|---|
| `/etc/tsx/buttons-board.conf` | The board package | The keys (`button` lines), the LED names and the settings that depend on the hardware. |
| `/etc/tsx/buttons.conf` | The user | Settings, more keys and actions (`on` lines). The file that the package installs is a template with no keys. |
| `/run/tsx/buttons.conf` | `tsx-config apply` | Settings only. It holds `LED_BLANK` when `panel.conf` has `KEY_LED_BLANK`. |

A `button` line with the name of an earlier key replaces that key. The actions of the name stay.

A panel has keys when a `button` line is in the board layer or in `buttons.conf`. Without a board layer and without a `button` line, the panel has no keys and no key entities in Home Assistant.

## Tasks

### Bind an action to a key

1. Open `/etc/tsx/buttons.conf`.
2. Add an `on` line, for example `on power long overlay full`.
3. Run `rc-service tsx-buttons reload`.

The name must be the name of a key. The press is `short`, `long` or `hold`. Several lines for the same key and press all run.

### Turn on the slide along the keys

The slide changes the brightness when a finger passes over the keys. It is off by default.

1. Open `/etc/tsx/buttons.conf`.
2. Add the line `SLIDE_STEP=2`. The number is the change of the backlight level for each key.
3. Run `rc-service tsx-buttons reload`.

The keys with `led=N` form the strip, in the order of N. A slide toward the key with the lowest N makes the screen brighter. With the slide on, a short press of a strip key fires `SLIDE_GAP_MS` after its release.

### Set the key LEDs

1. To set the level from a shell, run `tsx-keypad led 40`. Use `off` for dark keys and `auto` for the schedule.
2. To set the level of a blank screen, set `KEY_LED_BLANK` in `panel.conf` (0 to 255), or use the number in Home Assistant.

An override from `tsx-keypad led` or from Home Assistant holds across blank, wake and the change from day to night. `led auto` removes it.

### Add the keys of a board

1. Make the file `buttons-board.conf` in the board package.
2. Set `LED_PWM` to the LED class device that holds the brightness of all key LEDs.
3. Set `LED_KEY_PREFIX` so that `PREFIX1`, `PREFIX2` and so on are the enable LEDs.
4. Add one `button NAME KEYCODE led=N` line for each key.
5. Install the file as `/etc/tsx/buttons-board.conf`.

Use a key name that tells the user which key it is. The name is part of the Home Assistant entity of the key. A board without LEDs leaves out `led=N`, `LED_PWM` and `LED_KEY_PREFIX`.

## Reference

### Lines

| Line | Meaning |
|---|---|
| `SETTING=value` | A setting. |
| `button NAME KEYCODE [led=N]` | A key. `KEYCODE` is a name such as `KEY_F13` or a number. `N` is the number of its LED, 1 to 16. |
| `on NAME short\|long\|hold ACTION ARGS` | An action for a press. `short` fires on release, `long` fires after `LONG_PRESS_MS`, and `hold` repeats every `HOLD_REPEAT_MS` while the key is held. |

### Settings

| Setting | Layer | Default | Meaning |
|---|---|---|---|
| `LED_PWM` | Board | none | LED class device with the brightness of all key LEDs. Without it, the panel has no key LEDs. |
| `LED_KEY_PREFIX` | Board | none | Prefix of the enable LEDs. |
| `SLIDE_STEP` | Board | 0 | Change of the backlight level for each key of a slide. 0 turns the slide off. |
| `SLIDE_GAP_MS` | User | 250 | Time between two keys of a slide. |
| `LONG_PRESS_MS` | User | 700 | Time for a long press. |
| `HOLD_REPEAT_MS` | User | 300 | Repeat time of a hold. |
| `PRESS_FEEDBACK_MS` | User | 120 | Time that the LED of a pressed key stays dark. 0 turns it off. |
| `LED_DAY`, `LED_NIGHT` | User | 128, 24 | Key LED level by day and by night (0 to 255). |
| `LED_NIGHT_START`, `LED_NIGHT_END` | User | `NIGHT_START`, `NIGHT_END` of `kiosk.conf` | Night hours. |
| `LED_BLANK` | User | 24 | Key LED level while the screen is blank. `KEY_LED_BLANK` in `panel.conf` replaces it. |
| `HA_EVENT` | User | `tsx_button` | Name of the Home Assistant event. Empty turns it off. |
| `HA_URL`, `HA_TOKEN_FILE`, `HA_TIMEOUT` | User | origin of `KIOSK_URL`, `/etc/tsx/ha-token`, 10 | Home Assistant address, token file and time limit. Without a token, the HA event and the HA actions do not run. |
| `DEVTOOLS`, `NAV_FALLBACK` | User | `127.0.0.1:9222`, `none` | The browser interface for `home`, `reload` and `navigate`, and what to do without it. |
| `OVERLAY_FALLBACK` | User | `blank toggle` | The action for `overlay` when no overlay runs. |

The Default column shows the value that the template or the board layer sets, else the value of the program. A setting in a later layer replaces the same setting of an earlier layer. The board layer can hold any setting.

### Actions

| Action | Effect |
|---|---|
| `exec COMMAND` | Runs the command as root. The environment has `TSX_BUTTON` and `TSX_PRESS`. |
| `ha DOMAIN.SERVICE [JSON]` | Calls a Home Assistant service. |
| `ha-post /api/PATH [JSON]` | Sends a POST request to a Home Assistant path. |
| `navigate URL` | Opens a URL or a path in the kiosk. |
| `home` | Opens `KIOSK_URL`. |
| `reload` | Reloads the page. |
| `blank on\|off\|toggle` | Blanks or wakes the screen. |
| `brightness +N\|-N\|N\|auto` | Changes the backlight. `+N` and `-N` are an offset on top of the light sensor or the schedule. `N` is a fixed level until the next change from day to night. |
| `led +N\|-N\|N\|on\|off\|toggle\|auto` | Overrides the level of the key LEDs. |
| `overlay full\|slider\|hide\|toggle` | Controls the quick-settings overlay. |
| `none` | Does nothing. |

The highest backlight level is the `max` line of `/run/tsx/brightness.state`. Without it, it is `BACKLIGHT_MAX` of `panel-board.conf` or `kiosk.conf`, and then `max_brightness` of the backlight device.

### State

`/run/tsx/buttons.state` has these lines:

| Line | Meaning |
|---|---|
| `screen awake\|blank` | The screen state. |
| `leds yes\|no` | `yes` when a key has an LED and the `LED_PWM` device exists. |
| `led N SOURCE` | The level on the LEDs. `SOURCE` is `day`, `night`, `blank` or `override`. |
| `led_awake N SOURCE` | The level while the screen is awake. The light in Home Assistant shows it. |
| `led_blank N` | The level while the screen is blank. |
| `key_leds`, `key_override` | The state of each key LED. |
| `last NAME PRESS TIME` | The last key press. |

### Commands

| Command | Effect |
|---|---|
| `tsx-keypad led N\|+N\|-N\|on\|off\|toggle\|auto` | Sets the level of the key LEDs. |
| `tsx-keypad key N\|NAME on\|off\|auto` | Controls the LED of one key. `N` is the number of the LED. |
| `tsx-keypad press NAME [short\|long\|hold]` | Runs the actions of a key and fires the HA event. |
| `tsx-keypad reload` | Reads the configuration again. |
| `tsx-keypad status` | Shows `buttons.state`. |
| `tsx-panelctl has keypad` | Succeeds when the panel has keys. |
| `tsx-panelctl has keyleds` | Succeeds when the keys have LEDs (`leds yes`). |

## Home Assistant

| Entity | ESPHome object id | MQTT |
|---|---|---|
| Event of a key | `key_NAME` | Event `key_NAME` and the device triggers `button_short_press` and `button_long_press` |
| Light *Key LEDs* | `key_leds` | Light `key_leds` |
| Number *Key LEDs screen-off level* | `key_leds_screen_off` | none |

The light and the number exist only when `tsx-panelctl has keyleds` succeeds.

## Reload or open a page from a shell

`tsx-kiosk-page` sends one command to the browser. It needs `KIOSK_DEVTOOLS=1` in `kiosk.conf`. It needs no root, and it works on a panel with no keys. The overlay button *Reload page* runs `tsx-kiosk-page reload` (through `tsx-panelctl`).

| Command | Effect |
|---|---|
| `tsx-kiosk-page reload` | Reloads the page. |
| `tsx-kiosk-page home` | Opens `KIOSK_URL`. |
| `tsx-kiosk-page navigate URL` | Opens an `http` or `https` URL, or a path that starts with `/` on the origin of `KIOSK_URL`. |

The tool exits with 1 and prints a message when the browser does not answer.
