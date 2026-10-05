# Adaptive brightness

The automatic brightness maps the ambient light to a backlight level. The panel learns from manual changes. When the user holds a new level for a while, the panel keeps that level for that light.

The code is `base/usr/local/lib/tsx/tsx_brightness.py`.

## Tasks

### Make the panel forget the learned levels

Use one of these:

1. Run `tsx-panelctl send brightness-learn-reset`.
2. Or select "Forget the learned brightness" on the setup page.

Both remove `/data/tsx/brightness-learn.json` and set the flag `/run/tsx/brightness-learn.reset`. The daemon drops the points and goes back to the start curve.

### Turn the learning off

1. Set `BRIGHTNESS_LEARN=off` in `kiosk.conf`.
2. Restart the daemon.

The curve then stays fixed.

## How the curve works

The curve is a list of points (x, level). x is `log10(1 + lux)`. Between two points the level is a line in x. Before the first point and after the last point the level is flat.

1. The start curve has 5 base points. It runs from `BRIGHTNESS_NIGHT` at 0 lux to `BRIGHTNESS_DAY` at `AUTO_BRIGHTNESS_LUX`, as a line in x. A board with its own light service in shell gives the start curve as `ALS_CURVE` in `als.conf` (for example the xx60).
2. A manual change is an offset from the slider (`brightness-offset`). The program makes a user point when all of these are true:
    - Automatic brightness is on and the screen is lit.
    - The offset stays the same for `HOLD_S` (8 seconds).
    - `tsx-idled` uses the same offset (`brightness.state`).
    - The light stays inside a range of 0.15 in x (`STEADY_BAND`) during the hold.
    - The daemon has run for at least 20 seconds.
3. A new offset during the hold restarts the hold. A fixed level from Home Assistant (`brightness`) never teaches the curve.
4. The user point is the level on the glass (`level` in `brightness.state`) at the held light.
5. The new point replaces the points within 12 percent of the x range (`MERGE_DIST`).
6. The base points near the new point move by a part of the change. The part is 1 at the point and falls to 0 at three times the distance in step 5.
7. The curve never goes down when the light goes up. A darker point pulls the points on its left down to its level. A brighter point lifts the points on its right up to its level. The levels stay between `BACKLIGHT_MIN` and the top level.
8. The daemon takes the new level at once and removes the offset file. The slider shows the same level with an offset of 0.

A change of the light alone never makes a point and never removes one.

## Response to the light

The level follows the light with two hold times and two bands. The bands are in x.

1. The held light moves up when every reading of the last `AUTO_BRIGHTEN_S` seconds is more than `AUTO_BRIGHTEN_BAND` above it. It then takes the lowest of those readings.
2. The held light moves down when every reading of the last `AUTO_DARKEN_S` seconds is more than `AUTO_DARKEN_BAND` below it. It then takes the highest of those readings.
3. A flash or a shadow that is shorter than the time changes nothing. Noise inside the band changes nothing.
4. The level takes the curve value of the held light in one step. `tsx-idled` ramps the change.

The darken band is wider than the brighten band, so the level does not hunt around a step of the curve. A light service in shell reads the sensor at fixed intervals. For example, `tsx-als` of the xx60 reads the light every 0.8 seconds, the output period of its sensor.

## Settings

| Key | File | Default | Meaning |
|---|---|---|---|
| `BRIGHTNESS_LEARN` | `kiosk.conf` | `on` | `off` turns the learning off |
| `BRIGHTNESS_NIGHT` | board | board value | Level at 0 lux in the start curve |
| `BRIGHTNESS_DAY` | board | board value | Level at `AUTO_BRIGHTNESS_LUX` in the start curve |
| `BACKLIGHT_MIN` | board | 3 percent of `max_brightness`, at least 1 | Lowest lit level |
| `BACKLIGHT_MAX` | board | see "Numbers from the board" | Top level |
| `ALS_CURVE` | `als.conf` of the board | see "Numbers from the board" | Start curve of the daemon `als-daemon`, as `lux:level` pairs |
| `AUTO_BRIGHTNESS_LUX` | board | 500 | Light where the log curve reaches the top level, when the board gives no `ALS_CURVE` |
| `AUTO_BRIGHTEN_S` | `panel-board.conf` | 1.5 | Seconds that the light must stay brighter |
| `AUTO_BRIGHTEN_BAND` | `panel-board.conf` | 0.06 | Change in x that counts as brighter |
| `AUTO_DARKEN_S` | `panel-board.conf` | 5 | Seconds that the light must stay darker |
| `AUTO_DARKEN_BAND` | `panel-board.conf` | 0.10 | Change in x that counts as darker |
| `RAMP_SLIDER_MS` | `kiosk.conf` | 400 | Ramp time for a slider change. 0 is a jump |
| `RAMP_AUTO_MS` | `kiosk.conf` | 1000 | Ramp time for the ambient light, the schedule and a reload. 0 is a jump |

| Constant | Value | Meaning |
|---|---|---|
| `HOLD_S` | 8 s | Time that an offset must stay the same |
| `MERGE_DIST` | 0.12 | A new point replaces the points within this share of the x range |
| `SPREAD` | 3 | Base points within `SPREAD` times `MERGE_DIST` move by a part of the change |
| `MAX_POINTS` | 12 | User points kept. The oldest goes first |
| `STEADY_BAND` | 0.15 | Range of the light in x allowed during the hold |
| `GRACE_S` | 20 s | No learning in the first seconds after the daemon starts |

## Storage

The user points are in `/data/tsx/brightness-learn.json`: the lux, the level as a share of the top level, and the time. The file has at most 12 rows. It stays after a reboot and after a reinstall that keeps `/data`. The program rebuilds the curve from the base points and the user points, in the order of their time.

## Where it runs

The table gives the xx60 as an example. Another board can run its own daemon with the classes of `tsx_brightness.py`.

| Family | Daemon | How the curve reaches the backlight |
|---|---|---|
| xx60 | `tsx-als` (shell) starts `tsx_brightness.py als-daemon` | The daemon writes the whole curve to `/run/tsx/als-curve`. `tsx-als` uses it in place of `ALS_CURVE` and takes the new level at once |

The program rounds the curve value to a whole step. The hysteresis of `tsx-als` (a light change of 25 percent and a hold time) and the hysteresis band of the sensor daemon of a board stop the level from flipping between two steps.

## Numbers from the board

The code has no curve and no top level of its own. The daemon `als-daemon` takes them from the board:

1. The top level is `BACKLIGHT_MAX` of `panel-board.conf` (or `kiosk.conf`), but not above `max_brightness` of the backlight device. Without `BACKLIGHT_MAX`, it is the `max` line of `brightness.state`, then `max_brightness` of the device, then 31.
2. The lowest level is `BACKLIGHT_MIN`, else the `min` line of `brightness.state`, else 3 percent of the top level (at least 1).
3. The start curve is `ALS_CURVE` of `als.conf`. Without it, the daemon uses `log_ramp`: a line in x from the lowest level at 0 lux to the top level at `AUTO_BRIGHTNESS_LUX` (default 500 lux).

The daemon writes one line to its log when it uses the log ramp.

## Slider scale and ramp

- On a range of more than 64 levels, the slider position maps to the level with a square: level = min + (max - min) x position squared. The dark end has finer steps. On a range of 64 levels or less the scale is linear (for example the 24 steps of the xx60). The percent label under the slider is the level as a percent of the top level. The code is `kiosk/src/tsx-level.h`.
- `tsx-idled`, `tsx-overlay`, `tsx-panelctl` and `tsx-als` use `BACKLIGHT_MIN`. A blank screen has the backlight at 0, below `BACKLIGHT_MIN`. `tsx-idled` writes the value as `min` in `brightness.state`.
- `tsx-idled` ramps a change of the level. The ramp is even in the scale of the slider. The start and the wake from blank set the level at once. While the level is steady, `tsx-idled` has no ramp timer.
