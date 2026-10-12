# Security: users, groups and root helpers

The services of a panel run with the least privilege that they need. A service that talks to the network or draws the screen runs as its own user. The few actions that need root go through a root helper with a fixed list of commands. This page lists the users, the groups, the helpers and the services that stay root.

## Users

| User | Groups | Service | Package | What the user can do |
|---|---|---|---|---|
| `tsx-panel-app` | `tsx-panel-app`, `video`, `input`, `audio`, `tsx-setup-screen` | `tsx-panel-app` (the panel app) | tsx-panel-app | Draw on the display, read the touch and the keys, play sound and set the volume, write the backlight, the LEDs of the board and the CPU frequency limits, read the HA API key, read the pairing code of the setup page, write the FIFO of `tsx-panelctl` |
| `tsx-sendspin` | `audio` | `tsx-sendspin` (the Sendspin player) | tsx-sendspin | Play sound on the `media` PCM, use avahi over D-Bus, write its state folder `/var/lib/sendspin` and its log |
| `tsx-setup` | `tsx-setup`, `tsx-setup-screen` | `tsx-setupd` (the setup page) | tsx-setup | Serve the setup page, write the FIFO of `tsx-setup-helper` |
| `kiosk` | `kiosk`, `video`, `input`, `seat`, `render`, `audio` | the kiosk browser, the voice satellite | tsx-kiosk | Run the browser and the voice satellite, write the FIFO of `tsx-panelctl`, read the HA API key |

The install scripts of the packages make the users. An image build makes the same users. Each user has no password, no home folder and the shell `/sbin/nologin`.

The panel app runs as `tsx-panel-app` only when that user exists and the program supports it. `PANEL_APP_USER=root` in `/etc/tsx/panel-app.conf` makes it run as root again. See [Panel app](panel-app.md) "Service".

## Groups

| Group | Members | What it gives |
|---|---|---|
| `tsx-panel-app` | `tsx-panel-app` | Write access to the CPU frequency limits (`scaling_min_freq`, `scaling_max_freq`) and to the LEDs that the board names (`PANEL_APP_LEDS`). Read access to `/run/tsx/esphome.key` on a panel with no group `kiosk`. Write access to the FIFO `/run/tsx/panelctl` on a panel with no group `kiosk`. |
| `tsx-setup-screen` | `tsx-setup`, `tsx-panel-app` | Read access to `/run/tsx-setup/screen.json`: the pairing code that the panel app shows on the screen. The folder `/run/tsx-setup` has mode 710, so the group cannot list it. The other files in it stay mode 600. |
| `tsx-setup` | `tsx-setup` | Write access to the FIFOs of `tsx-setup-helper`. |
| `kiosk` | `kiosk` | Write access to the FIFO of `tsx-panelctl` and read access to the HA API key, on a panel with the kiosk. |
| `video` | `kiosk`, `tsx-panel-app` | The DRM devices `/dev/dri/*` and the backlight (a udev rule of tsx-base gives the group write access to `brightness` and `bl_power`). |
| `input` | `kiosk`, `tsx-panel-app` | The input devices `/dev/input/event*`. |
| `audio` | `kiosk`, `tsx-panel-app`, `tsx-sendspin` | The sound devices `/dev/snd/*`. |

The panel app gets DRM master without root: the kernel makes the first process that opens a DRM device its master. The panel app is the only DRM client on a panel with no kiosk.

Before each start, `tsx-panel-app-run --prepare` (root) gives the group `tsx-panel-app` write access to the sysfs files above. These sysfs files keep their owner and mode until the next boot.

## Root helpers

Two root daemons take commands from users that are not root. Each reads one line per command from a FIFO. Each accepts only the exact forms of its list, checks each number against a range and logs any other line. Neither one builds a shell command from the text of a line.

### tsx-panelctl

The FIFO is `/run/tsx/panelctl`, mode 660. The group is `kiosk` on a panel with the kiosk, else `tsx-panel-app`. The commands:

| Command | Action |
|---|---|
| `ledbar off\|on\|clear`, `ledbar set R G B`, `ledbar fx ...`, `ledbar led ...`, `ledbar side ...` | The USB LED bar (`tsx-ledbar`) |
| `usbpower on\|off` | The USB power of the board |
| `keypad led off\|auto\|N`, `keypad led-blank N` | The key LEDs |
| `blank on\|off` | The screen (the panel app or `tsx-blank`) |
| `brightness N`, `brightness-pct P`, `backlight N`, `brightness-offset N`, `brightness-learn-reset` | The backlight |
| `lights on\|off`, `lights set B R G B` | The lights of the panel app |
| `als auto on\|off` | The automatic brightness |
| `blank-timeout S`, `dim-timeout S`, `dim-level P`, `orientation NAME`, `config-url URL`, `verbose-boot on\|off` | A key of `panel.conf`, then `tsx-config apply` |
| `volume P` | The volume: `sendspin-cli player-vol P` while the Sendspin player runs (see [Sendspin](sendspin.md) "Audio and volume"), else `TSX_VOLUME_CMD` of the board or the `Master` control |
| `mute on\|off` | `sendspin-cli player-mute on\|off` while the Sendspin player runs. Else it is refused (the mixer has no mute) |
| `reload-page` | The page of the kiosk |
| `reboot` | `reboot` |
| `update-install` | `tsx-autoupdate now`: install at once, in both modes. See [Automatic update](autoupdate.md). |
| `update-mode auto\|manual`, `auto-restart on\|off` | A key of `panel.conf` (`UPDATE_MODE`, `UPDATE_AUTO_RESTART`), then `tsx-config apply` |
| `setup` | `tsx-config setup`: open the setup page for about 15 minutes |
| `layout-install ID` | `tsx-layout-check --install` of the fixed file `/run/tsx/panel-app/app/layout.ha` to `/var/lib/tsx/panel-layout.json`. The result goes to `/run/tsx/panel-app/layout.result`. |

The panel app as `tsx-panel-app` uses `reboot` (the overlay and the Restart button), `setup` (the overlay and the key action), `blank-timeout`, `dim-timeout` and `dim-level` (the overlay and Home Assistant), `update-install`, `update-mode` and `auto-restart` (the entities Update, Update mode and Automatic restart), `layout-install` (the action `set_layout`) and, while the Sendspin player runs, `volume` and `mute` (the overlay and Home Assistant). The control socket of the player is mode 600 for the user `tsx-sendspin`. Only root (the daemon) opens it. The app reads the volume from the file `/run/sendspin-cli/volume` (mode 644).

The daemon writes into the folder of the panel app only with a rename of a file that it made in `/run/tsx`. A rename never follows a link. Root owns the folder above, so the app cannot replace the folder with a link. `tsx-layout-check` opens the layout file with `O_NOFOLLOW` and refuses a file that is not a regular file.

### tsx-setup-helper

The FIFOs are `/run/tsx/setup-helper` and `/run/tsx/setup-helper.resp`, group `tsx-setup`. The commands are `show`, `rev`, `set KEY VALUE`, `unset KEY`, `apply`, `setup`, `kiosk-restart`, `brightness-learn-reset`, `clear-setup-open`, `layout-save`, `ha-token-set URL TOKEN`, `ha-token-clear`, `ha-entities`, `panel-state`, `panel CMD ARGS` and `rootpw PASSWORD`. The header of `setup/usr/local/sbin/tsx-setup-helper` describes each command. See also [Setup page](setup.md).

## Files

| File | Owner | Mode | Readers |
|---|---|---|---|
| `/data/tsx/panel.conf` | root | 600 | root only. The setup page reads it through `tsx-setup-helper`, which masks the secrets. |
| `/run/tsx/esphome.key` (the HA API key) | root, group `kiosk` or `tsx-panel-app` | 640 | `tsx-esphome` (root), the voice satellite, the panel app. Root owns it, so a reader cannot change the key. |
| `/var/lib/tsx/panel-app/` | root | 711 | The folder of the token of the layout editor (`ha-token`, root, 600). |
| `/var/lib/tsx/panel-app/app/` | `tsx-panel-app` | 700 | The ESPHome preferences and the backlight level of the app. |
| `/run/tsx/panel-app/` | root | 755 | The entity list from Home Assistant (`ha-entities.json`) and `layout.result`. |
| `/run/tsx/panel-app/app/` | `tsx-panel-app` | 755 | The state files of the app. The old paths `/run/tsx-idled.state`, `/run/tsx/panel-app.state`, `/run/tsx/panel-app/screen.state` and `/run/tsx/panel-app/entities.json` are links to it. |
| `/run/tsx/panel-app/control.d/` | `tsx-panel-app` | 755 | The commands of `tsx-panelctl` for the app. |
| `/run/tsx/update.state` | root | 644 | The update state for the panel app and `tsx-panelctl`: the versions, the summary, "restart required", the mode. |
| `/var/lib/sendspin/` | `tsx-sendspin` | 755 | The state of the Sendspin player. |

## Services that stay root

| Service | Why it needs root |
|---|---|
| `tsx-panelctl` | The root helper of the kiosk, the voice satellite and the panel app (see above). |
| `tsx-setup-helper` | The root helper of the setup page: `panel.conf`, `chpasswd`. |
| `tsx-config`, `tsx-data`, `tsx-hostname`, `tsx-setup` (boot) | They write `panel.conf`, the files of `/run/tsx`, the host name, the MAC, the time zone, the swap and the mounts. They run once at boot. |
| `tsx-autoupdate` | `apk upgrade` and the restart after an update. |
| `tsx-esphome`, `tsx-mqtt`, `tsx-bt` | The Home Assistant layer of the kiosk panels: the root-only tools of the board, the Bluetooth controller. |
| `tsx-ledbar` | The USB device of the LED bar. |
| `tsx-buttons`, `tsx-idled` | The input devices and the backlight of the kiosk panels, and the files that only root may write. |
| `tsx-banner` | It writes `/etc/motd` and `/etc/issue`. |

The board adds its own services. The board docs list them with the reason for root.
