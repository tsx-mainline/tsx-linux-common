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
      - lambda: id(panel_cards).key_press("home");
```

`tsx_drm` options:

| Option | Default | Meaning |
|---|---|---|
| `device` | empty | The DRM device, for example `/dev/dri/card0`. Empty: the first `/dev/dri/card*` with a connected output. The component skips a GPU render device, because it has no output. |
| `page_flip` | `true` | `false`: one dumb buffer and no flip. This copies less, but the screen can show a half-drawn area for one frame. |

The size of the display comes from the preferred mode of the output. The
snapshot action (`snapshot.take`) writes the screen copy to a BMP file.

`tsx_evdev` options:

| Option | Meaning |
|---|---|
| `device` | The input device path, for example `/dev/input/event0`. |
| `name` | A part of the device name (see `/proc/bus/input/devices`). Use `device` or `name`. |

The touchscreen platform takes the touch range from the device. The
`calibration`, `transform` and other options of the ESPHome touchscreen
schema also work. It reads multi-touch (protocol B) and single-touch
devices. Each touch report reaches LVGL in the next loop, so a fast swipe
keeps all its points.

A key of the `binary_sensor` platform is a name of
`linux/input-event-codes.h` (`KEY_F13`, `BTN_LEFT`) or a number. Set
`trigger_on_initial_state: true`: the first press after the start is the
first state of the sensor, and without the option ESPHome does not run
`on_press` for it.

The component does not grab the input device. Other programs still get the
events.

## Requirements

- The panel app must be the only program on the display. It becomes DRM
  master when it sets the mode. A compositor or another KMS program on the
  same output makes the start fail with "set the display mode".
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

- Avoid shadows and opacity below 100 % on large objects.
- Radius, borders and gradients cost little.
- Keep the display in RGB565. A 32-bit buffer costs 1.4 to 2.8 times more.
- The NEON blend code of LVGL (`LV_USE_DRAW_SW_ASM`) gives no gain on a
  Cortex-A8 and makes gradients slower. Keep it off.

## Troubleshooting

| Log line | Cause | Fix |
|---|---|---|
| `set the display mode (is another program on the display?)` | Another program is DRM master. | Stop the compositor or the other app. |
| `no DRM device with a connected output in /dev/dri` | No display driver, or the output is not connected. | Check `/sys/class/drm/*/status`. |
| `page flip failed` | The output is off. | The component writes into the shown buffer until a flip works again. |
| `no input device ... yet` | The input device is missing. | The component tries again every 5 s. Check `name` against `/proc/bus/input/devices`. |
