# Panel app display and input without SDL

Status: experimental, as the [panel app](panel-app.md). The options of the
components can change in a later release.

The panel app is an ESPHome program on the host platform with LVGL. Two
ESPHome components in `panel-app/esphome/components/` let it draw on the
screen and read touch and keys with no SDL, no EGL and no window system:

| Component | Platforms | What it does |
|---|---|---|
| `tsx_drm` | `display` | Shows the LVGL frames on a Linux DRM/KMS output with two dumb buffers and page flips. |
| `tsx_evdev` | `touchscreen`, `binary_sensor` | Reads the touch points and the keys of a Linux input device (`/dev/input/eventN`). |

Use them on a panel with a slow CPU, where the SDL path costs more time than
LVGL itself. Both components need the ESPHome host platform.

## How tsx_drm shows a frame

1. LVGL draws the changed areas into its draw buffer in RAM (RGB565).
2. `tsx_drm` copies each area into a full copy of the screen in cached RAM.
3. At the end of each LVGL refresh, `tsx_drm` copies the changed areas into
   the back dumb buffer. It also copies the areas of the frame before, so
   both buffers hold the full picture. A full-screen frame replaces them.
4. A page flip shows the back buffer at the next vertical blank.

The component never reads from the dumb buffers and never lets LVGL draw
into them. Dumb buffers are write-combined memory on many SoCs: the CPU
writes them at full speed, but reads are 10 to 40 times slower than reads
from cached RAM. Every blended or anti-aliased pixel reads its destination,
so a draw straight into a dumb buffer is slow.

The display is RGB565. The component sets `byte_order: little_endian` for
LVGL, so LVGL does not swap the bytes of each pixel.

## Configuration

```yaml
external_components:
  - source:
      type: local
      path: tsx-panel-app/components
    components: [tsx_drm, tsx_evdev]

display:
  - platform: tsx_drm
    id: panel_display

tsx_evdev:
  - id: panel_input
    name: ft5x06          # a part of the input device name, for example

touchscreen:
  - platform: tsx_evdev
    id: panel_touch

binary_sensor:
  - platform: tsx_evdev
    id: key_home
    key: KEY_F14
    trigger_on_initial_state: true
    on_press:
      - lambda: id(panel_cards).key_state("home", x);
```

`tsx_drm` options:

| Option | Default | Meaning |
|---|---|---|
| `device` | empty | The DRM device, for example `/dev/dri/card0`. Empty: the first `/dev/dri/card*` with a connected output. The component skips a GPU render device, because it has no output. |
| `page_flip` | `true` | `false`: one dumb buffer and no flip. This copies less, but the screen can show a half-drawn area for one frame. |
| `off_mode` | `dpms` | How `set_power(false)` makes the screen dark. `dpms`: the output goes off. `black`: the output stays on and shows a black frame (a third dumb buffer). |
| `dpms_after` | 0 s | With `off_mode: black`: the output also goes off after this dark time. 0 s: never. |
| `power_on_delay` | 0 ms | After the output comes on from DPMS off: the wait after the first frame, before `set_power(true)` returns. |

The size of the display comes from the preferred mode of the output. The
snapshot action (`snapshot.take`) writes the screen copy to a BMP file.

The component sets the display mode with the first frame of the app, not at
the start. Until then the screen keeps its picture, for example the boot
splash on the framebuffer. So the glass goes from the splash to the first
frame with no black frame between them. The log line `first frame: display
mode set` gives the time.

`set_power(false)` makes the screen dark. With `off_mode: dpms` it turns the
display output off with the DPMS property of the connector. A driver can
also cut the panel supply then. A panel that comes on again can show a
white frame before the picture. With `off_mode: black` the output stays on
and shows a black frame, so the panel stays powered.

`set_power(true)` turns the output on again if it is off. Then it puts the
full picture into the back buffer, flips to it and waits for the flip (at
most 50 ms). After DPMS off it also waits `power_on_delay`. So the caller
can turn the backlight on when the function returns, and the glass shows
the picture at once. While the screen is dark, the app can draw: the
screen copy keeps the changes. The log line `display on` gives the times.
The panel app calls `set_power` from the `on_screen` automation of
`tsx_cards` (see [Panel app](panel-app.md), "Screen"):

```yaml
tsx_cards:
  on_screen:
    - lambda: id(panel_display).set_power(on);
```

`tsx_evdev` options:

| Option | Meaning |
|---|---|
| `device` | The input device path, for example `/dev/input/event0`. |
| `name` | A part of the device name (see `/proc/bus/input/devices`). Use `device` or `name`. |
| `tap_time` | A touch that ends within this time (default 600 ms) with no finger moved more than 1/20 of the touch range is a tap. |

The touchscreen platform takes the touch range from the device. The
`calibration`, `transform` and other options of the ESPHome touchscreen
schema also work. It reads multi-touch (protocol B) and single-touch
devices. Each touch report reaches LVGL in the next loop, so a fast swipe
keeps all its points.

`tsx_evdev` adds its device to the `select()` list of the ESPHome main
loop. So an input event ends the wait of the loop at once, also with a long
loop interval. The event times use `CLOCK_MONOTONIC`.
`add_on_input_callback()` calls a function for each new touch, each later
touch report and each key press, before the touchscreen platform and LVGL
see the event. `tsx_cards` uses it for the wake and the CPU boost.

A key of the `binary_sensor` platform is a name of
`linux/input-event-codes.h` (`KEY_F13`, `BTN_LEFT`) or a number. Set
`trigger_on_initial_state: true`: the first press after the start is the
first state of the sensor, and without the option ESPHome does not run
`on_press` for it.

The component counts the fingers of each touch. `touch_count()` is the
number of fingers at this time. `gesture_fingers()` is the largest number of fingers
of the current touch, or of the last one. `take_tap()` gives the number of
fingers of the last tap once. `tsx_cards` uses them for the five-finger tap
of the settings overlay, and it ignores a tap on a card when more than one
finger touched the screen. `last_input_ms()` is the time of the last touch
or key event.

The component does not grab the input device. Other programs still get the
events.

## Requirements

- The panel app must be the only program on the display. It must be DRM
  master when it opens the device. A compositor or another KMS program on
  the same output makes the start fail with "another program is on the
  display".
- The binary needs `libdrm` at run time. The build needs the libdrm headers
  (`libdrm-dev` on Alpine).
- Only rotation 0 uses the fast copy. Rotate in the `lvgl:` block, not in
  the display.

## Drawing cost

LVGL draws in software. These relative costs come from full-screen redraws
of a card page (a grid of 12 cards with an icon and two labels) on a
single-core ARM CPU. A plain card page is 1.0.

| Style | Cost |
|---|---|
| Background only | 0.15 |
| Cards with no icon and no text | 0.5 |
| Cards with radius 0 | 0.8 |
| Card page (radius 14, icon, two labels) | 1.0 |
| Vertical gradient on each card | 1.05 |
| 2 px border on each card | 1.15 |
| Cards with 70 % opacity | 1.7 |
| 2 px outline on each card | 1.7 |
| Shadow on each card (width 16) | 2.5 |

- Avoid shadows and opacity below 100 % on large objects. The panel app
  shows a pressed card or button with another color, not with opacity, and
  its overlay and popups have a border, not a shadow.
- Radius, borders and gradients cost little.
- Keep the display in RGB565. A 32-bit buffer costs 1.4 to 2.8 times more.
- The NEON blend code of LVGL (`LV_USE_DRAW_SW_ASM`) gives no gain on a
  Cortex-A8 and makes gradients slower. Keep it off.

## Troubleshooting

| Log line | Cause | Fix |
|---|---|---|
| `another program is on the display (DRM master)` | Another program is DRM master. | Stop the compositor or the other app. |
| `set the display mode: ...` | The driver refused the mode of the first frame. | Check the output with `modetest` and the kernel log. |
| `no DRM device with a connected output in /dev/dri` | No display driver, or the output is not connected. | Check `/sys/class/drm/*/status`. |
| `page flip failed` | The output is off. | The component writes into the shown buffer until a flip works again. |
| `no input device ... yet` | The input device is missing. | The component tries again every 5 s. Check `name` against `/proc/bus/input/devices`. |
