# Automatic update

The package tsx-autoupdate installs the package updates of a panel. It runs on the kiosk panels and on the panels with the panel app. The board package of a family names it as a dependency.

## Modes

The mode decides when the panel installs an update. Both modes check on the schedule, so Home Assistant always shows the state of the packages.

| Mode | Behavior |
|---|---|
| `auto` | The panel installs inside `WINDOW` while the screen is idle. |
| `manual` | The panel never installs by itself. Home Assistant shows the update. A person starts the install. |

An install from Home Assistant (the Install button of the entity Update, or `tsx-autoupdate now`) installs at once in both modes. It ignores the window and the idle screen.

The setting Automatic restart decides what happens when the install needs a restart (see "Restart rule"):

| Automatic restart | Behavior |
|---|---|
| on | The panel restarts right after the install. An automatic install restarts inside the window. An install from Home Assistant restarts at once, also outside the window. |
| off | The panel stays up. Home Assistant shows "Restart required" until the panel restarts. |

With Automatic restart off, the entity Update keeps its entry in Settings → Updates after the install. Install on that entry restarts the panel. The Restart button does the same. The state ends at the next boot.

## Settings

Four places write the two settings:

- The Home Assistant entities "Update mode" (a select) and "Automatic restart" (a switch). See [ESPHome device](esphome.md) and [Panel app](panel-app.md).
- The Panel section of the [setup page](setup.md).
- The keys `UPDATE_MODE` (`auto` or `manual`) and `UPDATE_AUTO_RESTART` (`on` or `off`) of `panel.conf` (`tsx-config set`).
- `/etc/tsx/autoupdate.conf`.

`tsx-config apply` writes the keys of `panel.conf` to `/run/tsx/autoupdate.conf`. `tsx-autoupdate` reads `/etc/tsx/autoupdate.conf` and then that file, so the values of `panel.conf` win. A key that is not set in `panel.conf` leaves the value of `/etc/tsx/autoupdate.conf`. `tsx-autoupdate` reads the files at each run, so no service restart is needed.

| Key | Default | Meaning |
|---|---|---|
| `MODE` | `auto` | `auto` or `manual`. |
| `WINDOW` | `03:00-05:00` | The local time window for an automatic install and its restart. It can cross midnight. |
| `AUTO_RESTART` | `on` | `on` or `off`. |
| `HEALTH_TIMEOUT` | `180` | The longest time in seconds that the health check waits for the panel app. |

The older keys `ENABLED=0` (same as `MODE=manual`) and `REBOOT=never` (same as `AUTO_RESTART=off`) still work. They count only when `MODE` or `AUTO_RESTART` is not set.

## Schedule

The service `tsx-autoupdate` adds a line to `/etc/crontabs/root`. `crond` runs `tsx-autoupdate` every 15 minutes. Each run does these steps:

1. It runs `apk update` and `apk upgrade --simulate`. The pending list holds the upgrades and the new packages (a new dependency of an upgraded package).
2. In the mode `auto`, it installs only inside `WINDOW` and only while the screen is idle. In the mode `manual`, it stops here.
3. After the install, it restarts the panel if a package in the list needs a restart, `AUTO_RESTART` is on, and the time is inside `WINDOW`.

If an earlier install left "restart required" and `AUTO_RESTART` is on later, the next run in the window with an idle screen restarts the panel.

## Versions

Home Assistant shows release numbers, for example `0.3.5`. The release number is the version of the board package `PREFIX-board` (`PREFIX` is `TSX_PKG_PREFIX`, default `tsx-<family>`, for example `tsx-xx50-board`). A panel without that package uses the version of `tsx-base`.

| Field | Value |
|---|---|
| Installed version | The release that runs. `tsx-autoupdate` records it at each boot. |
| Latest version | The version of the board package in the repository index, when a newer one is pending. |

Other states of the latest version:

- Only other packages are pending: `<release> + N packages`. The summary lists the packages.
- The install needs a restart and the panel did not restart: `<release> (restart required)`. The release is the new one, or the running one when the release number did not change.
- Nothing is pending: the installed version.

## What Home Assistant shows

Home Assistant shows the title, the two versions and the release notes. The release notes are Markdown, with one package on each line.

| State | Title | Latest version | Release notes |
|---|---|---|---|
| Update pending | `TSX <host> packages` | `0.3.6` | "Packages to install:", a list, and the line "Restart needed after install." when the install needs a restart |
| Install runs | the same | the same | "Installing the packages. Do not switch the panel off." above the list. `in_progress` is on. Home Assistant shows a progress bar. |
| Installed, restart required | `Restart required to finish 0.3.6` | `0.3.6 (restart required)` | "Installed. Restart the panel to finish the update." and a line about Install and the Restart button |
| After the restart | `TSX <host> packages` | `0.3.6` | "up to date" |

The title and the latest version change after an install because of two limits of Home Assistant. The dialog of an update reads the release notes only when it opens. And the entity state does not change when the versions stay the same. So the title and the latest version show the new state at once. The release notes follow when the dialog opens again.

A repository warning is the last paragraph of the release notes. The installed version stays the running release in all states.

Home Assistant truncates the attribute `release_summary` to 255 characters. This affects only MQTT. A long list of packages ends early there. The ESPHome entities (kiosk and panel app) give the full text as release notes.

In `update-ha-state.json` the summary is one JSON string with `\n` for each newline. In `update.state` the summary is one line. A newline is the two characters `\n` and a backslash is doubled.

## Idle screen

The screen service writes the screen state to `/run/tsx-idled.state`. `tsx-idled` writes it on a kiosk panel. The panel app writes it on a panel with no kiosk. The file has one line:

| Line | Screen |
|---|---|
| `on LEVEL` | On or dim. `LEVEL` is the backlight value. |
| `on none` | The panel has no backlight. The screen is never idle. |
| `blank` | Off. This is the idle state. |

If the file does not exist (a panel app that does not write it), the screen is idle when every backlight in `/sys/class/backlight` is at 0. With no file and no backlight, the screen is never idle.

## Board hook

A board can define the function `tsx_board_pre_update` in `board.sh`. A board with A/B boot uses it to arm its boot slot, so that a bad upgrade falls back to the old system.

1. `tsx-autoupdate` runs `apk update` and `apk upgrade --simulate`.
2. If no package is pending, it stops. It does not call the function.
3. Before it runs `apk upgrade`, it calls the function and writes the output to the log.
4. If the function exits with a non-zero status, `tsx-autoupdate` does not start `apk upgrade`. It logs `ABORTED` and the status, and sets `last_result` to `pre-update hook rc=N`.

An aborted install changes nothing. The packages stay pending, and the next install tries again. Without the function, the install starts at once.

## Restart rule

These packages need a restart of the panel after the install. The rule applies to an upgrade and to a new package.

- The kernel package of the board family: `PREFIX-kernel*`. `PREFIX` is `TSX_PKG_PREFIX` of the board file. Without that value, it is `tsx-<family>` (`TSX_FAMILY` of the board file). The kernel package of another family needs no restart.
- `linux*`, `musl*`, `openrc*` and `busybox*`.
- Every other `tsx-*` package and every `PREFIX-*` package, except `tsx-keys` (a public key) and `tsx-ledbar-fw` (a tool). An upgrade of `tsx-ledbar-fw` never loads the LED bar: see [LED bar image](#led-bar-image). A running service keeps the code that it started with until it starts again.

## LED bar image

The package `tsx-ledbar-fw` can hold a newer firmware image for the LED bar. An upgrade never loads it, also not in the update window. A load that stops half way, for example by a power loss, can leave a bar that USB cannot recover. When the panel is set up for the TSX-LEDBAR firmware and the bar does not run the packaged version, the upgrade writes `/data/tsx/ledbar-fw.pending`. `tsx-autoupdate status` then shows the line `LED bar image`. To load the image, run `tsx-ledbar-fw-install` by hand. Run `tsx-ledbar-fw-install --status` to see the bar and the packaged image.

## Health check

Before an update restart, `tsx-autoupdate` writes `/var/lib/tsx/autoupdate/reboot-marker`. The marker also records whether the panel app had a Home Assistant connection. About 90 seconds after the next start of the service, `tsx-autoupdate healthcheck` checks the panel and removes the marker.

| Panel | The check |
|---|---|
| Kiosk (`/etc/init.d/kiosk` exists) | The `kiosk` service runs and the page of `KIOSK_URL` answers with an HTTP status 2xx or 3xx. |
| Panel app (`/etc/init.d/tsx-panel-app` exists and the service is in a runlevel) | The `tsx-panel-app` service runs. The process in `/run/tsx/panel-app.state` runs and drew its first frame. If the app had Home Assistant before the restart, it connected again. The check waits for this at most `HEALTH_TIMEOUT` seconds. |
| Neither | No check. The result is OK. |

The result is `OK` or `FAILED: REASON`. The status shows `checking` while the check runs. A panel with no update restart shows no result.

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
| `tsx-autoupdate` | One scheduled run: check, then install if the mode, the window and the screen allow it |
| `tsx-autoupdate now` | Check and install at once, in both modes. With nothing to install and "restart required", it restarts the panel. |
| `tsx-autoupdate check` | Check only |
| `tsx-autoupdate refresh` | Write the status files again from the saved state and the settings. It calls no `apk`. |
| `tsx-autoupdate boot` | Record the running release. The service calls it at each boot. |
| `tsx-autoupdate get mode\|auto-restart` | Print a setting |
| `tsx-autoupdate status` | The mode, the versions, the pending packages, "restart required", the last install, the health result, the repository state and, when one waits, a newer LED bar image |

| File | Contents |
|---|---|
| `/run/tsx/update.json` | The status (a copy is in `/var/lib/tsx/autoupdate`) |
| `/run/tsx/update-ha-state.json` | The status for the Home Assistant entity Update, and the fields `restart_required`, `mode` and `auto_restart` |
| `/run/tsx/update.state` | The same values as `key value` lines for the panel app and `tsx-panelctl`: `installed`, `latest`, `title`, `summary` (one line, `\n` for a newline), `in-progress`, `restart-required`, `mode`, `auto-restart` |
| `/run/tsx/autoupdate.conf` | The override that `tsx-config apply` writes from `panel.conf` |
| `/var/log/tsx-autoupdate.log` | The log |

If only the repositories of this project (`APK_URL`) are unreachable, the status shows a warning and the Alpine updates still install. An unreachable Alpine repository stops the install.
