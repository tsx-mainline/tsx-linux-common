# Layout

The repo has one directory for each package. A package directory holds the files as they sit on the panel. For example, `base/usr/local/sbin/tsx-config` installs as `/usr/local/sbin/tsx-config`. The packages follow the package split of tsx-aports.

## Packages

| Directory | Package | Contents |
|---|---|---|
| base | tsx-base | `tsx-config`, `tsx-hostname`, `tsx-setup`, `tsx-data`, `tsx-panelctl`, `tsx-board`, `tsx-rootpw`, the clock files (chrony, udhcpc hooks, `tsx-savetime`), the console banner, sysctl, sshd, profile, `serial.sh`, and `tsx_brightness.py` ([adaptive brightness](adaptive-brightness.md)) |
| kiosk | tsx-kiosk | `kiosk-session` (with the `kiosk.d` hook loader), `tsx-orientation`, `tsx-osk`, `tsx-kiosk-url`, `tsx-kiosk-page`, `tsx-kiosk-reveal`, `tsx-display-power`, `tsx-blank`, `kiosk.conf`, the Chromium policy, `tsx-idled` and `tsx-overlay` (C, with the header `tsx-level.h`) |
| setup | tsx-setup | `tsx-setupd`, `tsx-setup-helper`, their init scripts, `setup.conf`. See [Setup page without a kiosk](#setup-page-without-a-kiosk) |
| ha | tsx-ha | `tsx-mqtt`, `tsx-bt`, the voice scripts, the ESPHome shim (`tsx_panel`, `tsx_lva`), the setup page plugin, `install-lva.sh` |
| buttons | tsx-buttons | `tsx-buttons` (C), `tsx-keypad`, `buttons.conf` (a template with no keys). See [Front keys](buttons.md) |
| autoupdate | tsx-autoupdate | `tsx-autoupdate`, its init script, its conf, its logrotate file |
| ledbar | tsx-ledbar | `tsx-ledbar` (C), `tsx-ledbard`, its init script and `ledbar.conf`. See [LED bar](ledbar.md) |
| rescue | tsx-rescue-ui | `tsx-rescue-status`, `tsx-confont`, `tsx-rescue-login` |
| splash | tsx-splash | `tsx-splash` (C), the splash images and tools |
| panel-app | tsx-panel-app | The panel app: the ESPHome components `tsx_cards` and `tsx_runtime`, the generic ESPHome YAML and its patches, the service `tsx-panel-app` with `tsx-panel-app-run`, `tsx-layout-check` and the layout files. The program itself comes from the package of the board family. See [Panel app](panel-app.md) |
| tests | none | host tests, fixtures (`tests/boards`), helper programs |

`tsx_brightness.py` and `tsx-panelctl` are in tsx-base because every profile has tsx-base. The console profile has no tsx-kiosk. tsx-ha depends on `tsx-panelctl`.

## Services

| Service | Package | Function |
|---|---|---|
| tsx-config | tsx-base | Applies `panel.conf` as overrides in `/run/tsx` |
| tsx-hostname | tsx-base | Sets the host name: `PANEL_NAME` from `panel.conf`, else the name that the board suggests, else `<model>-<MAC>`, else `tsx-kiosk` |
| tsx-setup | tsx-base | Early setup: time zone, `eth0` MAC, zram swap, CPU governor |
| tsx-data | tsx-base | Moves the writable state to `/data` once and bind-mounts it at every boot |
| tsx-panelctl | tsx-base | Privileged command FIFO for the unprivileged Home Assistant plugin |
| kiosk | tsx-kiosk | Compositor and browser |
| tsx-idled | tsx-kiosk | Screen blanking with wake on touch, backlight schedule, backlight ramp |
| tsx-setupd | tsx-setup | On-panel setup page |
| tsx-setup-helper | tsx-setup | Privileged helper for the setup page |
| tsx-mqtt | tsx-ha | MQTT bridge to Home Assistant: LED bar, key LEDs, screen, backlight, keys |
| tsx-esphome | tsx-ha | Standalone Home Assistant ESPHome device for the panel |
| tsx-voice | tsx-ha | Assist voice satellite (ESPHome API) |
| tsx-bt | tsx-ha | Bluetooth controller, BLE scanner and BLE links for the Home Assistant Bluetooth proxy |
| tsx-sendspin | tsx-ha | Synchronized-audio player, configured in `/etc/tsx/sendspin.conf` |
| tsx-buttons | tsx-buttons | Front keys and key LEDs. The keys come from `/etc/tsx/buttons-board.conf`, the actions from `/etc/tsx/buttons.conf` |
| tsx-autoupdate | tsx-autoupdate | Schedules automatic Alpine package updates |
| tsx-ledbar | tsx-ledbar | Checks the LED bar, recovers it from bootloader mode and sends its color, effect and LED map |
| tsx-panel-app | tsx-panel-app | The panel app: Home Assistant cards on the screen with no browser. The board gives `/etc/tsx/panel-app-board.conf` |

## Not in this repo

These parts are board glue. They stay in the family repos:

- `board.sh`, `tsx-hw`, `tsx-boot-ok`, `tsx-update-boot`, `tsx-emmc-state`
- `tsx-als`, `tsx-cpufreqd`, `tsx-audio`, `asound.conf` and the tools of the audio chip
- `uboot-env.conf`, `tsx-chromium-es2` and the cage patch, `tsx-lib.sh` and the installers
- the initramfs init, `rcS` and `inittab`
- the Bluetooth chip file of a board and the tool that loads its firmware (see [Bluetooth chip file](#bluetooth-chip-file))
- the key definitions (`buttons-board.conf`)
- the parts of a board that use the plugin folders (see [Plugin folders](#plugin-folders)), for example the camera
- the image build (`mkrootfs.sh`, the profile lists, `profile.sh`) and the image tests
- the sensor, NFC, watchdog and firmware services of a family
- the family tests with the real board files (see [Tests](#tests))

## Board interface

The family repo gives the board values to this repo in `board.sh`, in the files below and in `/run/tsx`.

### board.sh

Variables: `TSX_FAMILY`, `TSX_APK_CATEGORY`, `TSX_HA_MODEL`, `TSX_SOUND_CARD`, `TSX_DISPLAY_DRM`, `TSX_RENDER_DRM`, `TSX_DISPLAY_ENV`, `TSX_BT_CHIP`, `TSX_BT_PROXY_DEFAULT`, `TSX_BT_MAC_SETTABLE`, `TSX_MAC_SOURCE`.

Functions: `tsx_board_model`, `tsx_board_stock_fw`, `tsx_board_unit_id`, `tsx_board_mac`, `tsx_board_mac_early`, `tsx_board_mac_source`, `tsx_board_hostname_hint`, `tsx_board_rescue_extra`, `tsx_board_load`, `tsx_board_probe`. Every function name starts with `tsx_board_`. A function prints its value, or nothing when the board has none. The functions `tsx_board_ha_model` and `tsx_board_ledbar_map` are optional (see the next table).

The shared scripts source only `board.sh`. A board that needs a helper file sources that file from its own `board.sh`. An example is a file that reads the board data in the rescue system. The rescue screen `tsx-rescue-status` names no helper file.

### Optional names

Every name in this table is optional. The neutral default applies when a board does not set it.

| Name | Used by | Meaning |
|---|---|---|
| `TSX_SERIAL_CONSOLE` | `serial.sh`, `tsx-config` service | Serial console name, for example `ttyS0`. Without it, `serial.sh` reads `/proc/consoles`. Root can log in on this console only when `/etc/securetty` lists it. The board package ships that file (see "Serial login") |
| `TSX_RENDER_ENV` | `kiosk-session` | `NAME=value` words for the GPU driver |
| `TSX_BROWSER_GL_FLAGS` | `kiosk-session` | Extra Chromium flags for GPU rendering |
| `/usr/local/lib/tsx/kiosk.d/*.sh` | `kiosk-session` | Hooks of the board. A hook can change the compositor, the browser mode, the GPU flags and the disabled features. See [Kiosk hooks](kiosk-hooks.md) |
| `TSX_VOLUME_CMD` | `tsx-panelctl` | Command that prints and sets the volume |
| `TSX_CONFIG_RELOAD` | `tsx-config` | Service names, separated by spaces. `tsx-config apply` writes `/run/tsx/sensors.conf` from the keys `PRESENCE_*`, `AUTO_BRIGHTNESS` and `ALS_SCALE`. When the file changes, `apply` runs `rc-service NAME reload` for each service of the list that runs. The first `apply` after boot reloads nothing, because the services read the file when they start. A board with no such service sets nothing |
| `tsx_board_ha_model` | `tsx-mqtt`, `tsx_panel` | Function that returns the model name for Home Assistant. Else `TSX_HA_MODEL`. When the result equals `TSX_HA_MODEL` (a family name), the ESPHome device shows the family name and "panel", for example "xx60 panel". Else it shows "Crestron" and the model name |
| `tsx_board_ledbar_map` | `tsx-ledbard` | Function that prints the name of the LED map for the LED bar of a panel model, or nothing for the firmware default map. Argument 1 is the model from `/run/tsx/model`. `LEDMAP` of `ledbar.conf` wins. See [LED bar](ledbar.md) "LED map" |
| `/etc/tsx/panel-board.conf` | `kiosk-session`, `kiosk`, `tsx-idled`, `tsx-cpufreqd` | The board layer of `kiosk.conf`: GPU mode, backlight range and floor (`BACKLIGHT_MAX`, `BACKLIGHT_MIN`), CPU governor, overlay tap, `ALS_WATCH`. `kiosk.conf` holds neutral defaults. The family ships this file in the base profile |
| `/etc/tsx/buttons-board.conf` | `tsx-buttons`, `tsx-panelctl`, `tsx-mqtt`, `tsx_panel` | The board layer of the front keys: the `button` lines, the LED names (`LED_PWM`, `LED_KEY_PREFIX`) and `SLIDE_STEP`. `tsx-buttons` reads it before `buttons.conf`. A board with no keys ships no file. See [Front keys](buttons.md) |
| `/etc/tsx/motd.board` | `profile.d/tsx.sh` | Lines for the login banner |
| `/etc/tsx/panel-app-board.conf` | `tsx-panel-app-run` | The environment, the folders and the device files of the panel app. See [Panel app](panel-app.md) "Service" |
| `rc_after` in `/etc/conf.d/tsx-config` | `tsx-config` | Services to wait for |
| `rc_after` in `/etc/conf.d/tsx-panelctl`, `tsx-esphome`, `tsx-mqtt` | the same services | The board names its own services that must start first (for example its light service). The init scripts of this repo name no service of a board |
| `/etc/tsx/als.conf` | `tsx_brightness.py als-daemon` | The start curve of the learner (`ALS_CURVE`) of a board with a light service in shell. See [Adaptive brightness](adaptive-brightness.md) |
| `REASON` in `hw.conf` | `tsx-config`, `tsx-setupd`, `tsx-voice`, `tsx_panel` | The text that says why a part is missing. The texts about a missing part end with `(REASON)`. Without `REASON`, they are short and have no brackets |
| `PRESENCE=no`, `LIGHT=no` in `hw.conf` | `tsx-config`, `tsx-setupd` | The `tsx-hw` of the board writes these for a panel without that part |
| `LEDBAR=no` in `hw.conf` | `tsx-panelctl` | The `tsx-hw` of the board writes `LEDBAR=no` for a panel model without a LED bar. Then `tsx-panelctl has ledbar` fails, also with a bar attached, and Home Assistant gets no LED bar entity. A missing file or key is not `no`. See [LED bar](ledbar.md) "When Home Assistant shows the LED bar" |
| `/run/tsx/ledbar.usb` | `tsx-ledbard`, `tsx-panelctl` | One word: `app` (a bar with its application is attached) or `bootloader` (a bar in recovery). `tsx-ledbard` writes it. No file means no bar. `tsx-panelctl has ledbar` needs `app`. The ESPHome device and `tsx-mqtt` show the LED bar only then |
| `/run/tsx/model` | `tsx-ledbard`, `tsx-banner` | The model of the panel. `tsx-hostname` writes it at boot from `tsx_board_model`. The file can be missing |
| `/run/tsx/*.state` | `tsx-panelctl`, `tsx_panel` | Files of the board daemons: presence, usb-power, poe, nfc, brightness. The tool `tsx-ledbar` writes `ledbar.state` |
| `/run/tsx/ledbar.fw` | `tsx-panelctl` | The firmware of the LED bar: the lines of `tsx-ledbar fw` and `caps WORDS`. The service `tsx-ledbar` (`tsx-ledbard`, root) writes it. Without it, `has ledbar-fx` and `has ledbar-leds` run `tsx-ledbar fw`, which gives the full answer only to root |

### Values that a board sets

- the serial console name (inittab, kiosk init, `tsx-ip.start`) and `/etc/securetty`
- the display and render driver names
- the GPU variables and the Chromium flags
- the browser rules for a GPU (a hook in `kiosk.d`)
- the backlight range and the `kiosk.conf` defaults (GPU mode, CPU governor, overlay trigger)
- the front keys, their key codes and their LEDs (`buttons-board.conf`)
- the MAC and identity store (`tsx-setup`, `tsx-hostname`)
- the volume command
- the services that reload when the sensor settings change (`TSX_CONFIG_RELOAD`)
- the Home Assistant model name
- the LED map of the bar for a panel model (`tsx_board_ledbar_map`)
- the boot status lines of the motd
- the eMMC state tool
- the Bluetooth chip file (`TSX_BT_CHIP`)
- the order of `tsx-config`
- the order of `tsx-panelctl`, `tsx-esphome` and `tsx-mqtt` (`rc_after` in `/etc/conf.d`)
- the start curve of the light service (`als.conf`) and the top and lowest backlight level (`panel-board.conf`)

`tsx-idled` can apply `als-level` at once. This is the board key `ALS_WATCH=1`. It is off by default, because the light service of a board can ramp the backlight itself (for example `tsx-als` of the xx60).

### Serial login

Root can log in on the serial console only when `/etc/securetty` names it. The login program reads only this file. The board package ships it: the list of the Alpine `busybox` package plus the serial console of the board. The board package declares `replaces="busybox"` for it. No package of `tsx-linux-common` ships or changes `/etc/securetty`, and no boot script edits it.

The same rule holds for each file of a package. When a script changes such a file, `apk` writes a `.apk-new` file at each upgrade of the package. So `/etc/motd` has no owner among the TSX packages: `tsx-banner` writes it at boot.

### Bluetooth chip file

`tsx-bt` holds the steps that every board needs. The steps of one Bluetooth chip are in a chip file. The board names the file in `TSX_BT_CHIP` of `board.sh`. A board whose kernel driver registers `hciN` by itself sets `TSX_BT_CHIP=none`. A board that sets nothing does the same. For example, the xx60 board package ships the chip file for its CSR8811 controller.

`tsx-bt` reads the chip file with `.`. The file defines these functions:

| Function | Meaning |
|---|---|
| `chip_up` | Reset the chip, load its firmware and attach it to the kernel. Set `HCI` to the new `hciN` if the file knows it. `MAC` is the address to load, or empty (the chip keeps its own address). Call `fail TEXT` on an error |
| `chip_down` | Detach the chip and hold it in reset |
| `chip_absent_reason` | Print why the board has no Bluetooth module. This function is optional. Without it, `tsx-bt` prints the `REASON` of `hw.conf` |

The file can use these names of `tsx-bt`: `log`, `fail`, `hw_get`, `hci_list`, `state`, and the variables `RUN`, `SYS`, `PROC`, `HCI`, `MAC` and `PSRKIND`. `PSRKIND` names the firmware that the file loaded. `tsx-bt` writes it to the state file as `psr=`. The file owns all other names.

When `hw.conf` says `BT=no`, `tsx-bt` never calls `chip_up` or `chip_down`. It writes `state=absent` with the reason and exits with 0. When `TSX_BT_CHIP` names a file that is missing, `tsx-bt` logs a warning and runs with no chip steps. The state is `failed` if `hciN` does not show up.

The test `tests/test-bt.sh` uses a made-up chip file. The tests of a real chip file are in the repo of the board.

## Plugin folders

A board package adds parts to the shared software with files in plugin folders. The shared packages do not name the parts. A panel without the files behaves as a panel without the parts.

| Folder | Read by | File | Adds | Test hook |
|---|---|---|---|---|
| `/usr/local/share/tsx/setup.d` | `tsx-setupd` | `NAME.py` | Fields of the setup page. The contract is in `ha/usr/local/share/tsx/setup.d/ha.py`. | `TSX_SETUP_PLUGIN_DIR` |
| `/usr/local/share/tsx/esphome.d` | `tsx-esphome` and the voice satellite | `NAME.py` | Entities and API messages of the ESPHome device (see [ESPHome device](esphome.md#plugins)) | `TSX_ESPHOME_PLUGIN_DIR` |
| `/usr/local/lib/tsx/config.d` | `tsx-config` | `NAME.sh` | Keys of `panel.conf` | `TSX_CONFIG_PLUGIN_DIR` |
| `/usr/local/lib/tsx/kiosk.d` | `kiosk-session` | `NAME.sh` | Changes of the renderer choice and the browser flags (see [Kiosk hooks](kiosk-hooks.md)) | `TSX_KIOSK_HOOK_DIR` |

A file in `esphome.d`, `config.d` or `kiosk.d` loads only when root owns it and the folder, and the group and others cannot write them. A link does not load. For `esphome.d` and `config.d`, the test hook `TSX_PLUGIN_OWNER_UID` changes the owner that the loaders accept (default 0). For `kiosk.d`, the test hook is `TSX_KIOSK_HOOK_UID`. A test sets the id of its own user.

### config.d

`tsx-config` reads each `NAME.sh` of the folder, in name order, when it starts. `NAME` has lowercase letters, digits and `_`. The file defines only variables and functions. Its keys then work like the keys of `tsx-config`: `get`, `set`, `validate`, `unset`, `show` and `apply`. The setup page uses `validate`, so it accepts these keys too.

| Name | Meaning |
|---|---|
| `CFG_NAME_KEYS` | The keys of the plugin, separated by spaces. Required. A key has capital letters, digits and `_`. A key that `tsx-config` or an earlier plugin has already is ignored, with a log line. |
| `CFG_NAME_SECRET_KEYS` | The keys among them that `show` masks. |
| `cfg_NAME_valid KEY VALUE` | Exit with 0 when the value is valid. Required. |
| `cfg_NAME_missing KEY` | When the panel lacks the part of the key, print why and exit with 0. Else exit with 1. `set` and `show` use it for a warning. Use `hw_get REASON` for the reason. |
| `cfg_NAME_apply` | Write the override files of the plugin. `apply` runs it once. |
| `CFG_NAME_SIG` | Set by `cfg_NAME_apply`. `apply` adds this text to the restart signatures of `tsx-esphome` and `tsx-voice`. They restart when the text changes. |

In these names, `NAME` is the file name in lowercase for the functions and in capitals for the variables. A plugin in `fakeopt.sh` defines `CFG_FAKEOPT_KEYS` and `cfg_fakeopt_valid`.

A plugin can use these helpers of `tsx-config`:

| Helper | Meaning |
|---|---|
| `cfg_get KEY` | Prints the value of a key of `panel.conf`. It fails when the key is not set. |
| `hw_get KEY` | Prints a value of `/run/tsx/hw.conf`, for example `REASON`. |
| `hw_why` | Prints ` (REASON)` with the `REASON` of `hw.conf`, or nothing when `hw.conf` has no `REASON`. Use it at the end of a text about a missing part. |
| `hw_warn KEY VALUE` | Logs the warning for a part that is missing, when `cfg_NAME_missing` says so. |
| `write_override PATH [MODE]` | Writes its standard input to the file. Empty input removes the file. |
| `shq TEXT` | Quotes a value for a file that a script sources. |
| `log TEXT` | Writes a line to the log. |
| `RUN` | The folder `/run/tsx`. |

Example, for a made-up key `FAKEOPT`:

```sh
CFG_FAKEOPT_KEYS="FAKEOPT"

cfg_fakeopt_valid() { case "$2" in off|low|high) return 0;; esac; return 1; }

cfg_fakeopt_missing() {
	[ "$(hw_get FAKEOPT)" = no ] || return 1
	echo "this panel has no fake option$(hw_why)"
}

cfg_fakeopt_apply() {
	mode=$(cfg_get FAKEOPT) || mode=off
	if cfg_fakeopt_missing FAKEOPT >/dev/null; then hw_warn FAKEOPT "$mode"; mode=off; fi
	printf 'FAKEOPT="%s"\n' "$mode" | write_override "$RUN/fakeopt.conf" 644
	CFG_FAKEOPT_SIG=$mode
}
```

A file that fails a check gives one log line and is skipped. These are the checks:

- The owner and the write bits are right.
- The name is right.
- The file loads. A syntax error or a failing command stops it.
- The file defines `CFG_NAME_KEYS` and `cfg_NAME_valid`.

The other files still load.

A panel without the plugin does not know its keys. `tsx-config set` refuses them, and `tsx-config apply` logs one warning for each such key in `panel.conf` and ignores it. So a `panel.conf` from another panel still loads.

A host run from a checkout, for example the installer, has no `/usr/local/lib/tsx`. There `tsx-config` reads `config.d` next to the script (`../lib/tsx/config.d`), as it does for `board.sh`. For a user that is not root, it does not check the owner of this folder. Root always checks it.

## Setup page without a kiosk

A panel can run with no browser kiosk. The package tsx-kiosk is not installed, and a native panel app owns the screen. The key `TSX_SETUP_KIOSK` of `/etc/tsx/setup.conf` sets the mode of `tsx-setupd`. Its values are `auto`, `on` and `off`. With `auto` (the default), the mode is on when `/etc/kiosk.conf` exists. The environment variable `TSX_SETUP_KIOSK` replaces the key. Tests use it.

With the mode off, the setup page changes in these ways:

| Part | With no kiosk |
|---|---|
| Page URL card (`KIOSK_URL`) | Hidden. A save does not need a URL, and it ignores a URL that a client sends. No kiosk loads a page. |
| Screen blank timeout (`BLANK_TIMEOUT`) | Hidden. Only `tsx-idled` reads it, and `tsx-idled` is a service of tsx-kiosk. A save leaves the key as it is. |
| Login method and token (`HA_LOGIN_METHOD`, `HA_TOKEN`, from the plugin of tsx-ha) | Hidden. Only the browser of the kiosk reads them. A save leaves the keys as they are. |
| Panel name, time zone, orientation, sensors, root login, updates | Shown. Services outside tsx-kiosk read these keys: `tsx-hostname`, `tsx-setup`, `tsx-splash`, `tsx-buttons`, the console and the sensor services of the board. |
| Configured | `panel.conf` has at least one key. |
| First save | While the panel is not configured, a save always sends `TZ_NAME`, also when it did not change. The page selects the time zone of the browser, or UTC. So the first save makes `panel.conf` and closes the LAN listener, as on a panel with a kiosk. |
| After a save | No kiosk restarts. The end of the LAN window restarts no kiosk. |

A plugin names the keys that only the kiosk reads in `KIOSK_ONLY_KEYS`. The slot `kiosk` of the script of the page hides the fields of the plugin.

### screen.json

A native screen cannot read the pairing code from the page. So `tsx-setupd` writes the code to the file `screen.json` in its state folder. The folder is `/run/tsx-setup` (mode 0700, owner `tsx-setup`). The init script makes it. The environment variable `TSX_SETUP_STATE_DIR` changes it for tests.

The daemon writes the file while `lan_allowed()` is true. That is the case while the panel is not configured and for the window after `tsx-config setup`. It writes the file at least every 5 s (every 2 s in practice). It writes a temporary file with mode 600 and renames it, so a reader never sees half a file. It removes the file when the LAN window closes, when the process ends and at the start. The file is one JSON object:

```json
{"code": "123456", "port": 8080, "path": "/setup", "addresses": ["192.0.2.10"], "remaining": 840, "uptime": 1234}
```

| Key | Meaning |
|---|---|
| `code` | The pairing code. |
| `port`, `path` | The port of `tsx-setupd` and the path of the setup page. |
| `addresses` | The IPv4 addresses of the panel that are not loopback. The list can be empty. |
| `remaining` | The seconds until the code expires. |
| `uptime` | The seconds of `/proc/uptime` at the write, as an integer. |

A native app shows "Setup: http://ADDR:PORT/setup  code CODE" while the file exists and its `uptime` is less than 30 s older than `/proc/uptime`. The code stays on the state API of the loopback address, as on a panel with a kiosk.

## Tests

| Command | Runs |
|---|---|
| `tests/run-all.sh` | The host tests that need no compiler |
| `tests/run-all.sh --c` | Also the C tests (`tsx-idled`, `tsx-buttons`, `tsx-splash`, the overlay layout) |
| `tests/run-all.sh --net` | Also the ESPHome tests `test-esphome.sh`, `test-esphome-ledbar.sh` and `test-esphome-wakewords.sh` (need pip) |
| `tests/test-tsx-data-chroot.sh` | The `tsx-data` test. It needs a container and is not in the list |
| `ci/lint.sh` | The lint: shell syntax, Python byte-compile, init script modes, proprietary files, doc links |
| `ci/check-generic.sh` | The gate: no family name, chip or family value outside `docs/`. See "The generic gate" |

A test that needs a board file uses the made-up board in `tests/boards/fake`. A test sources `tests/lib/board.sh`, which sets `TSX_BOARD_CONF` and `TSX_BOARD_BIN`. The board holds `board.sh`, `panel-board.conf`, `buttons-board.conf` and `motd.board`. It also holds a fake plugin for each plugin folder: `config.d/fakeopt.sh` and `esphome.d/fakeent.py`. A test of a loader sets the test hook of the folder to a copy of the folder. `test-config-plugins.sh` covers `config.d`. `test-shim-plugins.sh` and `test-esphome.sh` cover `esphome.d`. The values of the board differ from the values of every real family. So a test fails when shared code has a family value built in. `test-board-fake.sh` runs the shared scripts against this board and against a second made-up board. It also runs `kiosk-session` with fake `kiosk.d` hooks.

`test-panel-app-run.sh` covers the start script of the panel app: the identity from the host name and the MAC, the saved identity, the board file. `test-panel-editor.sh` covers the setup page of a panel with no kiosk and `screen.json`. It starts the real `tsx-setup-helper` and the real `tsx-setupd`. `test-setup.sh` covers the presence fields of the setup page (shown with `PRESENCE=yes`, hidden with `PRESENCE=no`). It also covers the save rule: a save writes only the changed fields, and the server refuses a page with an old revision of `panel.conf`. `test-setup-page.sh` runs the script of the setup page in node, with a small fake DOM. It checks the changed fields that a save sends and the refresh every 20 s. Without node, it prints SKIPPED. It also covers the hidden fields of a panel with no kiosk. `test-panel-board.sh` covers the board layer of `kiosk.conf`.

### Tests of a family

The tests with the real board files are in the repo of each family, in `rootfs/tests/common/`. This repo holds no copy of a board file. To run them:

1. Check out this repo in the folder `tsx-linux-common` next to the family repo, or set `TSX_COMMON` to the top of the checkout.
2. Run `rootfs/tests/common/run.sh` in the family repo.

A family test sources `tests/lib/paths.sh` of this repo to find a shared file by its path on the panel. The CI of a family repo checks out this repo and runs the same command.

### The generic gate

`ci/check-generic.sh` fails when a file outside `docs/` has a family word in its text or in its name. The words are family names, panel model names, serial console names, SoC and GPU driver names, chip names, and the names of parts that only one family has (for example the camera). The gate uses `git grep`.

A line passes when it has the text "for example" or "e.g." on the same line as the word. The file `ci/check-generic.allow` lists the other cases. Each entry has a file pattern, a pattern for the allowed words and the reason. Keep the list short. An entry that allows nothing is an error. The gate also checks each `docs/NAME.md` in a comment. The page must be a page of this repo, and a quoted heading must be a heading of the page. A comment names the docs of the board repository in words. `tests/test-generic-gate.sh` plants hits and checks that the gate fails on them.
