# Layout

The repo has one directory for each package. A package directory holds the files as they sit on the panel. For example, `base/usr/local/sbin/tsx-config` installs as `/usr/local/sbin/tsx-config`. The packages follow the package split of tsx-aports.

## Packages

| Directory | Package | Contents |
|---|---|---|
| base | tsx-base | `tsx-config`, `tsx-hostname`, `tsx-setup`, `tsx-data`, `tsx-panelctl`, `tsx-board`, `tsx-rootpw`, the clock files (chrony, udhcpc hooks, `tsx-savetime`), the console banner, sysctl, sshd, profile, `serial.sh`, and `tsx_brightness.py` ([adaptive brightness](adaptive-brightness.md)) |
| kiosk | tsx-kiosk | `kiosk-session`, `tsx-orientation`, `tsx-osk`, `tsx-kiosk-url`, `tsx-kiosk-reveal`, `tsx-display-power`, `tsx-blank`, `kiosk.conf`, the Chromium policy, `tsx-idled` and `tsx-overlay` (C, with the header `tsx-level.h`) |
| setup | tsx-setup | `tsx-setupd`, `tsx-setup-helper`, their init scripts, `setup.conf` |
| ha | tsx-ha | `tsx-mqtt`, `tsx-bt`, the voice scripts, the ESPHome shim (`tsx_panel`, `tsx_lva`), the setup page plugin, `install-lva.sh`, the Bluetooth chip files |
| buttons | tsx-buttons | `tsx-buttons` (C), `tsx-keypad`, `buttons.conf` |
| autoupdate | tsx-autoupdate | `tsx-autoupdate`, its init script, its conf, its logrotate file |
| rescue | tsx-rescue-ui | `tsx-rescue-status`, `tsx-confont`, `tsx-rescue-login` |
| splash | tsx-splash | `tsx-splash` (C), the splash images and tools |
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
| tsx-buttons | tsx-buttons | Front-panel keys and key LEDs. The actions come from `/etc/tsx/buttons.conf` |
| tsx-autoupdate | tsx-autoupdate | Schedules automatic Alpine package updates |

## Not in this repo

These parts are board glue. They stay in the family repos:

- `board.sh`, `tsx-hw`, `tsx-boot-ok`, `tsx-update-boot`, `tsx-emmc-state`
- `tsx-als`, `tsx-cpufreqd`, `tsx-audio`, `asound.conf`, the LED bar and TFA tools
- `uboot-env.conf`, `tsx-chromium-es2` and the cage patch, `tsx-lib.sh` and the installers
- the initramfs init, `rcS` and `inittab`
- the image build (`mkrootfs.sh`, the profile lists, `profile.sh`) and the image tests
- the sensor, NFC, light bar, watchdog and firmware services of a family
- `tsx-voice-hook` (it calls the light tool of the board), `tsx-voice-run`, the asound names for the audio devices, and the `after` line of `tsx-esphome`, which lists `avahi-daemon` on the xx60 only

## Board interface

The family repo gives the board values to this repo in `board.sh`, in the files below and in `/run/tsx`.

### board.sh

Variables: `TSX_FAMILY`, `TSX_APK_CATEGORY`, `TSX_HA_MODEL`, `TSX_SOUND_CARD`, `TSX_DISPLAY_DRM`, `TSX_RENDER_DRM`, `TSX_RENDER_ES2_DRM`, `TSX_DISPLAY_ENV`, `TSX_BT_CHIP`, `TSX_BT_PROXY_DEFAULT`, `TSX_BT_MAC_SETTABLE`, `TSX_MAC_SOURCE`.

Functions: `tsx_board_model`, `tsx_board_stock_fw`, `tsx_board_unit_id`, `tsx_board_mac`, `tsx_board_mac_early`, `tsx_board_mac_source`, `tsx_board_hostname_hint`, `tsx_board_rescue_extra`, `tsx_board_load`, `tsx_board_probe`. Every function name starts with `tsx_board_`. A function prints its value, or nothing when the board has none.

### Optional names

Every name in this table is optional. The xx60 behavior applies when a board does not set it.

| Name | Used by | Meaning |
|---|---|---|
| `TSX_SERIAL_CONSOLE` | `serial.sh` | Serial console name, for example `ttyAML0`. Without it, the script reads `/proc/consoles` |
| `TSX_RENDER_ENV` | `kiosk-session` | `NAME=value` words for the GPU driver |
| `TSX_BROWSER_GL_FLAGS` | `kiosk-session` | Extra Chromium flags for GPU rendering |
| `TSX_VOLUME_CMD` | `tsx-panelctl` | Command that prints and sets the volume |
| `tsx_board_ha_model` | `tsx-mqtt`, `tsx_panel` | Function that returns the model name for Home Assistant. Else `TSX_HA_MODEL`. When the result equals `TSX_HA_MODEL` (a family name), the ESPHome device shows "xx60 panel". Else it shows "Crestron" and the model name |
| `/etc/tsx/panel-board.conf` | `kiosk-session`, `kiosk`, `tsx-idled`, `tsx-cpufreqd` | The board layer of `kiosk.conf`: GPU mode, backlight range and floor (`BACKLIGHT_MAX`, `BACKLIGHT_MIN`), CPU governor, overlay tap, `ALS_WATCH`. `kiosk.conf` holds neutral defaults. The family ships this file in the base profile |
| `/etc/tsx/motd.board` | `profile.d/tsx.sh` | Lines for the login banner |
| `rc_after` in `/etc/conf.d/tsx-config` | `tsx-config` | Services to wait for |
| `PRESENCE=no`, `LIGHT=no` in `hw.conf` | `tsx-config`, `tsx-setupd` | The `tsx-hw` of the board writes these for a panel without that part. The xx60 `tsx-hw` writes `PRESENCE=no` |
| `/run/tsx/*.state` | `tsx-panelctl`, `tsx_panel` | Files of the board daemons: presence, usb-power, poe, nfc, brightness |
| `/run/tsx/ledbar.fw` | `tsx-panelctl` | The firmware of the LED bar: the lines of `tsx-ledbar fw` and `caps WORDS`. The LED bar service of the board (root) writes it. Without it, `has ledbar-fx` and `has ledbar-leds` run `tsx-ledbar fw`, which gives the full answer only to root |

### Values that a board sets

- the serial console name (inittab, kiosk init, `tsx-ip.start`, securetty)
- the display and render driver names
- the GPU variables and the Chromium flags
- the Chromium ES2 path
- the backlight range and the `kiosk.conf` defaults (GPU mode, CPU governor, overlay trigger)
- the MAC and identity store (`tsx-setup`, `tsx-hostname`)
- the volume command
- the Home Assistant model name
- the boot status lines of the motd
- the eMMC state tool
- the order of `tsx-config`

`tsx-idled` can apply `als-level` at once. This is the board key `ALS_WATCH=1`. It is off by default, because the xx60 `tsx-als` ramps the backlight itself.

## Tests

| Command | Runs |
|---|---|
| `tests/run-all.sh` | The host tests that need no compiler |
| `tests/run-all.sh --c` | Also the C tests (`tsx-idled`, `tsx-buttons`, `tsx-splash`, the overlay layout) |
| `tests/run-all.sh --net` | Also the ESPHome tests `test-esphome.sh`, `test-esphome-ledbar.sh` and `test-esphome-wakewords.sh` (need pip) |
| `tests/test-tsx-data-chroot.sh` | The `tsx-data` test. It needs a container and is not in the list |
| `ci/lint.sh` | The lint: shell syntax, Python byte-compile, init script modes, proprietary files, doc links |

A test that needs a board file uses a copy in `tests/boards/<family>`. The copy holds `board.sh`, `panel-board.conf`, `motd.board` and, if the family has it, `conf.d-tsx-config`. `test-setup.sh` covers the presence fields of the setup page (shown with `PRESENCE=yes`, hidden with `PRESENCE=no`). It also covers the save rule: a save writes only the changed fields, and the server refuses a page with an old revision of `panel.conf`. `test-setup-page.sh` runs the script of the setup page in node, with a small fake DOM. It checks the changed fields that a save sends and the refresh every 20 s. Without node, it prints SKIPPED. `test-panel-board.sh` covers the board layer of `kiosk.conf`.

### Check the board fixtures

To check that the copies match a family checkout:

1. Run `tests/check-boards.sh xx60=PATH`. PATH is the top of the family checkout.
2. Read each difference that the command prints. The command exits with 1 when a copy differs.
3. Copy the changed board file into `tests/boards/<family>`.

The CI of this repo cannot reach the family repos, so it does not run this check. The CI of a family repo can run it after a checkout of this repo.
