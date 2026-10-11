# Automatic update

The package tsx-autoupdate installs the package updates of a panel. It runs on the kiosk panels and on the panels with the panel app. The board package of a family names it as a dependency.

## Schedule

The service `tsx-autoupdate` adds a line to `/etc/crontabs/root`. `crond` runs `tsx-autoupdate` every 15 minutes. Each run does these steps:

1. It runs `apk update` and `apk upgrade --simulate`. The pending list holds the upgrades and the new packages (a new dependency of an upgraded package).
2. It installs only inside `WINDOW` and only while the screen is idle.
3. After the install, it reboots if a package in the list needs a reboot, and only inside `WINDOW`.

`/etc/tsx/autoupdate.conf` holds the settings. After a change, run `rc-service tsx-autoupdate restart`.

| Key | Default | Meaning |
|---|---|---|
| `ENABLED` | `1` | `0` stops the scheduled runs. `tsx-autoupdate now` and `tsx-autoupdate status` still work. |
| `WINDOW` | `03:00-05:00` | The local time window for the install and the reboot. It can cross midnight. |
| `REBOOT` | `auto` | `never`: no automatic reboot. The status then shows "reboot pending" until a person reboots the panel. |
| `HEALTH_TIMEOUT` | `180` | The longest time in seconds that the health check waits for the panel app. |

## Idle screen

The screen service writes the screen state to `/run/tsx-idled.state`. `tsx-idled` writes it on a kiosk panel. The panel app writes it on a panel with no kiosk. The file has one line:

| Line | Screen |
|---|---|
| `on LEVEL` | On or dim. `LEVEL` is the backlight value. |
| `on none` | The panel has no backlight. The screen is never idle. |
| `blank` | Off. This is the idle state. |

If the file does not exist (a panel app that does not write it), the screen is idle when every backlight in `/sys/class/backlight` is at 0. With no file and no backlight, the screen is never idle.

## Reboot rule

These packages need a reboot. The rule applies to an upgrade and to a new package.

- The kernel package of the board family: `tsx-<family>-kernel*` (`TSX_FAMILY` of the board file). The kernel package of another family needs no reboot.
- `linux*`, `musl*`, `openrc*` and `busybox*`.
- Every other `tsx-*` package, except `tsx-keys` (a public key) and `tsx-ledbar-fw` (a tool). A running service keeps the code that it started with until it starts again.

## Health check

Before an update reboot, `tsx-autoupdate` writes `/var/lib/tsx/autoupdate/reboot-marker`. The marker also records whether the panel app had a Home Assistant connection. About 90 seconds after the next start of the service, `tsx-autoupdate healthcheck` checks the panel and removes the marker.

| Panel | The check |
|---|---|
| Kiosk (`/etc/init.d/kiosk` exists) | The `kiosk` service runs and the page of `KIOSK_URL` answers with an HTTP status 2xx or 3xx. |
| Panel app (`/etc/init.d/tsx-panel-app` exists) | The `tsx-panel-app` service runs. The process in `/run/tsx/panel-app.state` runs and drew its first frame. If the app had Home Assistant before the reboot, it connected again. The check waits for this at most `HEALTH_TIMEOUT` seconds. |
| Neither | No check. The result is OK. |

The result is `OK` or `FAILED: REASON`. The status shows `checking` while the check runs. A panel with no update reboot shows no result.

The panel app writes `/run/tsx/panel-app.state` at its start, at its first frame and at each change of the Home Assistant connection:

| Key | Value |
|---|---|
| `pid` | The process ID of the app |
| `started` | The start time (epoch seconds) |
| `first_frame` | The time of the first frame on the screen (epoch seconds), 0 before it |
| `ha_connected` | The time of the first Home Assistant connection (epoch seconds), 0 before it |
| `ha` | `on` while Home Assistant is connected, else `off` |

## Commands and files

| Command | Function |
|---|---|
| `tsx-autoupdate` | One scheduled run (check, then install if the window and the screen allow it) |
| `tsx-autoupdate now` | Check and install at once. The window still controls the reboot. |
| `tsx-autoupdate check` | Check only |
| `tsx-autoupdate status` | The installed state, the pending packages, the last install, the health result and the repository state |

| File | Contents |
|---|---|
| `/run/tsx/update.json` | The status (a copy is in `/var/lib/tsx/autoupdate`) |
| `/run/tsx/update-ha-state.json` | The status for the Home Assistant update entity |
| `/var/log/tsx-autoupdate.log` | The log |

If only the repositories of this project (`APK_URL`) are unreachable, the status shows a warning and the Alpine updates still install. An unreachable Alpine repository stops the install.
