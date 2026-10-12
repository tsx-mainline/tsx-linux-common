# Panel app

Status: experimental. The layout format and the component settings can change in a later release. The xx60 boards use the browser kiosk and do not ship the program. A board that uses the app ships the program in its own package.

The panel app shows Home Assistant cards on the panel screen with no browser. It is an ESPHome program for Linux (the ESPHome `host` platform) with an LVGL screen. The cards come from a JSON layout file. The app reads the file when it starts and again when the file changes. A change of the layout needs no new build and no restart.

The app is one ESPHome device in Home Assistant. It reads the states of the entities in the layout and sends the action of a card when you tap it.

One program serves all panels of a family. The program holds no value of one panel. The service gives it the device name, the MAC and the API encryption key at start (see "Identity and API key").

## Parts

| Path | Contents |
|---|---|
| `panel-app/esphome/components/tsx_cards/` | The ESPHome component `tsx_cards` (C++). It reads the layout, makes the pages and cards, subscribes to the states and sends the actions. It also shows the setup banner and writes the entity list. It runs the screen (`screen.cpp`), the settings overlay (`overlay.cpp`), the detail popups (`popup.cpp`) and the slider cards (`slider.cpp`, with the numbers in `slider_logic.h`) and the update entities (`update.cpp`, `update.py` and `update_logic.h`, see "Updates"). |
| `panel-app/esphome/components/tsx_leds/` | The ESPHome light platform `tsx_leds` (C++): a light on a Linux LED device (see "Panel lights"). |
| `panel-app/usr/local/lib/tsx/config.d/panel_app.sh` | The plugin of `tsx-config` with the keys `DIM_TIMEOUT` and `DIM_LEVEL` (see "Screen"). |
| `panel-app/esphome/components/tsx_runtime/` | The ESPHome component `tsx_runtime` (C++). It sets the device name and the API encryption key at run time. |
| `panel-app/esphome/patches/host-mac.patch` | A patch for the `host` component of ESPHome: the MAC comes from the environment. The board build applies it to the generated project. |
| `panel-app/etc/init.d/tsx-panel-app` | The OpenRC service. |
| `panel-app/usr/local/sbin/tsx-panel-app-run` | The start script of the service: the identity, the environment of the board, then the program. |
| `panel-app/etc/tsx/panel-app.conf` | The settings of the service. |
| `panel-app/esphome/panel-app.yaml` | The generic part of the ESPHome configuration: the API, the Home Assistant time, the icon font, LVGL and `tsx_cards`. A board includes it as a package. |
| `panel-app/esphome/icon-glyphs.yaml` | The glyph list of the icon font. `mkicons.py` writes it. |
| `panel-app/esphome/mkicons.py` | Writes `icons.h` and `icon-glyphs.yaml` from `icons.txt`. `--check` tells if they are out of date. |
| `panel-app/usr/local/bin/tsx-layout-check` | Checks a layout file with the same rules as the app. With `--install`, it also installs a checked layout. |
| `panel-app/usr/local/bin/tsx-ha-entities` | Reads the list of entities from Home Assistant, for the layout editor. See "Entity picker". |
| `panel-app/usr/local/share/tsx/setup.d/panel_layout.py` | The plugin of the setup page: the link to the editor, the field for the API encryption key and the API of the editor. |
| `panel-app/usr/local/share/tsx/panel-app/layout-editor.html` | The page of the layout editor: one HTML file with its CSS and its script. |
| `panel-app/usr/local/share/tsx/panel-app/icons.txt` | The icons of the app: the MDI name and the code point. |
| `panel-app/usr/local/share/tsx/panel-app/example-layout.json` | An example layout with made-up entities. |
| `panel-app/usr/local/share/tsx/panel-app/layout.schema.json` | A JSON schema of the layout format, for editors. |

## The board part

A board gives the parts that the generic YAML does not know. The board YAML does these things:

1. It sets `esphome: name` and `friendly_name`, and the platform (for example `host:`).
2. It includes `panel-app.yaml` with `packages:` and the components `tsx_cards` and `tsx_runtime` with `external_components:`.
3. It makes a display with the id `panel_display` and a touchscreen with the id `panel_touch`. On a slow CPU, use the `tsx_drm` display and the `tsx_evdev` touchscreen and keys (see [Panel app display and input](panel-accel.md)).
4. It sends each change of a key of the panel to the app: `id(panel_cards).key_state("NAME", x)` in `on_state`. Use the key names of `buttons-board.conf` (for example `home`, `up`, `down`). A key that is a binary sensor needs `trigger_on_initial_state: true`. Without it, ESPHome ignores the first press after the start.
5. Optional: it gives `tsx_cards` the input (`input_id`), the panel lights, the event entities of the keys and the `on_screen` automation (see "Component settings").
6. It applies the patches of `panel-app/esphome/patches` to `src/esphome` of the generated project (`patch -p1`).

The board YAML has no value of one panel and needs no `secrets.yaml`. The board package installs the program as `/usr/local/bin/tsx-panel-app` and the file `/etc/tsx/panel-app-board.conf` (see "Service"). The board docs tell how to build it.

## Component settings

| Setting | Default | Meaning |
|---|---|---|
| `layout_files` | `/var/lib/tsx/panel-layout.json`, `/etc/tsx/panel-layout.json` | The layout files, in order. The app uses the first file that exists. The environment variable `TSX_PANEL_LAYOUT` adds a file in front of the list. |
| `time_id` | none | The time component for the clock cards. Without it, a clock card shows `--:--`. |
| `page_bar_height` | 36 | The height of the page bar at the bottom of the screen, in pixels. 0 removes the bar. |
| `setup_file` | `/run/tsx-setup/screen.json` | The file of the setup page with the pairing code (see "Setup banner"). An empty text turns the banner off. |
| `entities_file` | `/run/tsx/panel-app/entities.json` | The entity list for the layout editor (see "Entity list"). An empty text turns it off. |
| `input_id` | none | A `tsx_evdev` input. With it, a five-finger tap opens the settings overlay, and a touch with two fingers or more taps no card. |
| `panel_lights` | none | The ESPHome lights of the key action `"lights"` (see "Panel lights"). |
| `key_events` | none | A map from a key name to an ESPHome event entity (see "Key events"). |
| `backlight` | `auto` | The backlight folder, for example `/sys/class/backlight/backlight`. `auto` takes the first folder of `/sys/class/backlight`. |
| `dim_timeout`, `blank_timeout`, `dim_level` | 60 s, 300 s, 30 % | The defaults of the screen (see "Screen"). |
| `overlay_timeout` | 10 s | The time with no touch before the settings overlay closes. |
| `on_screen` | none | An automation that runs when the screen goes off (`on` is false) or comes on again (`on` is true). |
| `screen_off_loop_interval` | 0 ms | The main loop interval while the screen is off. 0 ms keeps the interval. Use it only with `input_id`: `tsx_evdev` ends the wait of the loop at once for a touch or a key. |
| `fonts` | | The fonts: `small` (states, page bar), `label` (card names), `value` (sensor values), `clock` (the time) and `icon`. A font is an LVGL font name (for example `montserrat_20`) or the id of an ESPHome font. The `icon` font must hold the glyphs of `icon-glyphs.yaml`. |

`/var/lib/tsx` keeps its contents after an image update (see the service `tsx-data` in [Layout](layout.md)). So the layout of the user goes there. A board can ship a default layout in `/etc/tsx`.

## Layout format

The layout file is a JSON object. Example:

```json
{
  "version": 1,
  "grid": {"columns": 4, "rows": 3, "gap": 10},
  "keys": {"home": "page:1", "up": "prev_page", "down": "next_page"},
  "pages": [
    {
      "name": "Kitchen",
      "cards": [
        {"type": "clock", "w": 2},
        {"type": "weather", "entity_id": "weather.home", "w": 2},
        {"type": "light", "entity_id": "light.kitchen", "label": "Kitchen"},
        {"type": "switch", "entity_id": "switch.coffee_maker", "icon": "mdi:coffee"},
        {"type": "scene", "entity_id": "scene.dinner"},
        {"type": "sensor", "entity_id": "sensor.kitchen_temperature", "precision": 1}
      ]
    }
  ]
}
```

### Top level

| Key | Required | Meaning |
|---|---|---|
| `version` | yes | Always 1. |
| `grid` | no | The default grid of the pages: `columns` (1 to 12, default 4), `rows` (1 to 12, default 3) and `gap` in pixels (0 to 40, default 10). |
| `theme` | no | Colors as `"#RRGGBB"`: `background`, `card`, `card_on` (a card that is on), `text`, `text_dim`. |
| `keys` | no | The action of each key of the panel. See "Keys". |
| `pages` | yes | The pages, 1 to 16. |

### Pages

| Key | Meaning |
|---|---|
| `name` | The name in the page bar. Default "Page N". |
| `columns`, `rows` | The grid of this page. The default comes from `grid`. |
| `cards` | The cards, 0 to 48. |

The page bar shows the page names. Tap a name to show its page. A swipe to the left shows the next page, and a swipe to the right shows the previous page. A swipe does not go past the first or the last page. The page changes at once, with no animation. A finger that moves more than 24 pixels, or that slides off the card, makes no tap. The page bar also shows "Not connected" while Home Assistant is not connected. It shows "Layout error" when the last change of the file has an error.

### Cards

| Key | Cards | Meaning |
|---|---|---|
| `type` | all | `light`, `switch`, `scene`, `script`, `sensor`, `weather`, `clock`, `cover`, `climate`, `media_player`, `fan`, `conditional` or `slider`. Required. |
| `entity_id` | all but `clock` | The Home Assistant entity. Required. A `light`, `scene`, `script`, `weather`, `cover`, `climate`, `media_player` or `fan` card needs an entity of that domain. A `slider` card needs a `light`, `fan`, `cover`, `media_player`, `number` or `input_number` entity. A `conditional` card takes any entity. It is the entity of the condition. |
| `label` | all but `conditional` | The name on the card. Default: the friendly name of the entity. |
| `icon` | all but `clock` and `conditional` | An icon as `"mdi:name"`. The name must be in `icons.txt`. Default: an icon for the type and the state. |
| `w`, `h` | all | The size in cells. Default 1. |
| `x`, `y` | all | The cell of the top left corner, from 0. Give both or none. |
| `tap` | all but `conditional` | The action of a tap. See "Actions". Default: the action of the type. |
| `hold` | all but `clock` and `conditional` | The action of a long press (about 0.4 s). It has the same values as `tap`. Default: the detail popup of a `light`, `fan`, `cover`, `media_player` or `climate` card. The other types do nothing. See "Detail popups". |
| `attribute` | `sensor` | Show this attribute of the entity, not its state. |
| `unit` | `sensor`, `slider` | The unit text. Default: the `unit_of_measurement` of the entity (a `slider` in percent shows `%`). On a `slider` card, an empty text shows no unit. |
| `precision` | `sensor` | The number of decimals of a numeric value (0 to 6). Default: the value as Home Assistant sends it. |
| `format` | `clock` | The format of the time (strftime). Default `%H:%M`. |
| `date_format` | `clock` | The format of the date (strftime). Default `%a %d %b`. An empty text removes the date. |
| `step` | `climate` | The change of the target temperature for one tap on - or +. A number from 0.1 to 10. Default: the attribute `target_temp_step` of the entity, else 0.5. |
| `orientation` | `slider` | `"horizontal"` (default) or `"vertical"`. See "Slider cards". |
| `min`, `max` | `slider` | The ends of the slider: numbers from -1000000000 to 1000000000, `min` less than `max`. A `light`, `fan`, `cover` or `media_player` slider is in percent, so its `min` and `max` are 0 to 100. A `number` slider uses the unit of the entity. Default: the range of the entity. |
| `send` | `slider` | When the slider sends its action: `"release"` (default) when the finger lifts, or `"drag"` also while the finger moves. |
| `state` | `conditional` | A text, or a list of 1 to 16 texts. The inner card shows while the entity has one of these states. |
| `state_not` | `conditional` | A text, or a list of 1 to 16 texts. The inner card shows while the entity has none of these states. |
| `card` | `conditional` | The inner card: an object with the keys of a card. Required. |

The card types:

| Type | Shows | Default tap |
|---|---|---|
| `light` | On with the brightness in percent, or Off. The card has the `card_on` color when the light is on. | `light.toggle` |
| `switch` | On or Off. For a `switch`, `input_boolean` or other entity that has the action `toggle`. | `DOMAIN.toggle` |
| `scene` | A run button. | `scene.turn_on` |
| `script` | A run button. "Running" while the script runs. | `script.turn_on` |
| `sensor` | The state (or an attribute) and the unit. | none |
| `weather` | The condition, the temperature and the humidity. | none |
| `clock` | The local time and date from Home Assistant. | none |
| `cover` | The state (Open, Closed, Opening or Closing) and the position in percent. Three buttons: open, stop and close. The card has the `card_on` color while the cover is open or moves. | `cover.toggle` |
| `climate` | The current temperature, the mode and the target temperature. Two buttons, - and +, change the target by `step`. The card has the `card_on` color while the mode is not `off`. | none |
| `media_player` | The state, or the title and the artist while the player plays. Also the volume. Three buttons: volume down, play/pause and volume up. The card has the `card_on` color while the player plays. | none |
| `fan` | On with the speed in percent, or Off. The card has the `card_on` color while the fan is on. | `fan.toggle` |
| `conditional` | The inner card while the condition is true. Else the cells stay empty. | The tap of the inner card |
| `slider` | A slider for the entity, its value and its unit. See "Slider cards". | `light.toggle`, `fan.toggle`, `cover.toggle`, mute on or off for a `media_player`, none for a `number` |

A value that is not known yet shows `--`.

The buttons of the cards send these Home Assistant actions:

| Button | Action |
|---|---|
| `cover`: open, stop, close | `cover.open_cover`, `cover.stop_cover`, `cover.close_cover` |
| `climate`: - and + | `climate.set_temperature` with the value `temperature` |
| `media_player`: volume down, play/pause, volume up | `media_player.volume_down`, `media_player.media_play_pause`, `media_player.volume_up` |

A `conditional` card shows its inner card only while its condition is true. The entity of the card gives the state. The card needs `state` or `state_not`, and not both. An empty text matches an empty state. The card also needs a `card` object.

The inner card is any card but a `conditional` card. It follows the normal rules of a card. It has no place of its own, because the `conditional` card sets the place and the size. So the app ignores `x`, `y`, `w` and `h` of the inner card. The checker gives a warning for each of them. A `conditional` card has only the keys `type`, `entity_id`, `x`, `y`, `w`, `h`, `state`, `state_not` and `card`. For any other key, the checker gives the warning "unknown key".

Example:

```json
{"type": "conditional", "entity_id": "binary_sensor.front_door", "state": "on",
 "card": {"type": "switch", "entity_id": "switch.porch_light", "label": "Porch Light"}}
```

### Placement

The app gives each card its cells in two steps:

1. The cards with `x` and `y` get their cells, in the order of the list.
2. The other cards get the first free cells, row by row, in the order of the list.

A card that overlaps an earlier card, or that has no free place, is left out. A `conditional` card takes its cells at all times, also while its inner card is hidden.

### Detail popups

A long press on a `light`, `fan`, `cover`, `media_player` or `climate` card opens a detail popup. This is the default of `hold`. Give `"hold": "none"` to turn the popup off. Give an action object to replace the popup with that action.

| Card | The popup shows |
|---|---|
| `light` | A slider for the brightness (`light.turn_on` with `brightness_pct`). The buttons On and Off. |
| `fan` | A slider for the speed (`fan.set_percentage`). The buttons On and Off. |
| `cover` | A slider for the position (`cover.set_cover_position`). The buttons Open, Stop and Close. |
| `media_player` | A slider for the volume (`media_player.volume_set`). The buttons Previous, Play/Pause and Next. |
| `climate` | A button for each mode in `hvac_modes` (`climate.set_hvac_mode`). The buttons - and +. |

A tap outside the popup closes it. The popup also closes after 10 s with no touch. The inner card of a `conditional` card has its own `tap` and `hold`.

### Slider cards

A `slider` card has a slider for one value of its entity. The domain of the entity sets what the slider changes:

| Domain | The slider changes | Action of the slider | The card shows |
|---|---|---|---|
| `light` | The brightness, 0 to 100 % | `light.turn_on` with `brightness_pct`. 0 % sends `light.turn_off`. A light with only on and off (`supported_color_modes`) gets `light.turn_on` with no brightness. | The brightness, or Off. The card has the `card_on` color when the light is on. |
| `fan` | The speed, 0 to 100 %, in the steps of `percentage_step` | `fan.set_percentage` with `percentage` | The speed, or Off. The card has the `card_on` color when the fan is on. |
| `cover` | The position, 0 to 100 % | `cover.set_cover_position` with `position` | The position. The card has the `card_on` color while the cover is open or moves. |
| `media_player` | The volume, 0 to 100 % | `media_player.volume_set` with `volume_level` (0.00 to 1.00) | The volume, or Muted, or Off. The card has the `card_on` color while the player plays. |
| `number`, `input_number` | The value, from the attributes `min`, `max` and `step` | `number.set_value` or `input_number.set_value` with `value` | The value and the unit. |

Drag the slider, or tap a point of the slider, to set the value. A tap on the card outside the slider runs `tap`. The default tap turns a light or a fan on or off and toggles a cover. On a `media_player` card it turns the mute on or off (`media_player.volume_mute`), when the player has the mute feature. A `number` card has no default tap. A long press runs `hold`. A slider card has no detail popup.

The slider sends its action when the finger lifts. With `"send": "drag"`, it also sends while the finger moves, at most one action in 0.3 s. So a drag does not flood Home Assistant. The slider sends nothing when the value did not change.

The slider follows the state of Home Assistant while no finger is on it. After a send, it keeps the sent value for up to 3 s, until Home Assistant reports it. So an older state does not make the slider jump back.

The `min` and `max` of the layout narrow the range. A `number` slider keeps the limits of its entity. When the entity has no `min`, `max` or `step` attribute, the slider uses 0, 100 and 1. A slider has at most 100000 positions. A larger range uses a larger step.

These rules apply to the touch:

- The touch that wakes a dark or dim screen does nothing (see "Screen").
- A touch with more than one finger never sends a slider action. The slider goes back to the state of Home Assistant.
- A swipe that starts on the slider moves the slider and does not change the page. Start a page swipe outside the sliders.

The slider shows no knob and sends nothing while the entity is unavailable or has no value yet. The same applies to a `cover` with no position feature, to a `media_player` that is off or has no volume feature, and to a `number` with no usable range. The tap on the card still works.

A horizontal slider sits between the icon and the name. A vertical slider fills the right side of the card, with the icon, the value and the name on the left. The slider has no shadow, no outline and no transparency, so a drag redraws only the slider and the value. The log line `slider drag` (tag `perf`) gives the frames and the render time of each drag.

Example:

```json
{"type": "slider", "entity_id": "light.kitchen", "label": "Kitchen", "w": 2},
{"type": "slider", "entity_id": "cover.living_room_blinds", "orientation": "vertical", "h": 2},
{"type": "slider", "entity_id": "input_number.washer_delay", "min": 0, "max": 12, "unit": "h", "send": "drag"}
```

### Actions

A `tap` value, a `hold` value or a `keys` value is one of these:

| Value | Meaning |
|---|---|
| `"default"` | The default action of the card type (`tap` and `hold` only). |
| `"none"` | Nothing. |
| `"page:N"` | Show page N, from 1 (`keys` only). |
| `"setup"` | Open the setup window of the panel: the app runs `tsx-config setup` (`keys` only). |
| `"overlay"` | Open the settings overlay of the app (`keys` only). |
| `"lights"` | Turn the panel lights on or off (see "Panel lights"). This is a local action and sends nothing to Home Assistant (`keys` only). |
| `"screen_off"` | Turn the screen off at once (`keys` only). |
| `"next_page"`, `"prev_page"` | Show the next or the previous page. After the last page comes the first page (`keys` only). |
| `{"action": "domain.service", "data": {...}}` | Send this Home Assistant action. The values of `data` are texts, numbers or true/false. |

A tap on a card sends the action with the `entity_id` of the card, unless `data` has its own `entity_id`. The app sends the `data` values as templates, so Home Assistant gets `50` as a number.

Home Assistant runs the action only when the option "Allow the device to perform Home Assistant actions" of the ESPHome device is on. Else Home Assistant refuses the action, and nothing changes in the home.

### Keys

The board names its keys (for example `power`, `home`, `lights`, `up`, `down`). Without an entry in `keys`:

| Key | Action |
|---|---|
| `home` | `"page:1"` |
| `up` | `"prev_page"` |
| `down` | `"next_page"` |
| `power` | `"overlay"` |
| `lights` | `"lights"` |
| any other key | `"none"` |

### Errors

The app leaves out a card with an error and shows the other cards. The log has a line for each such card. A file that the app cannot use at all (bad JSON, no pages, a wrong `version`) does not change the screen. When the app has no usable layout yet, the screen shows the error.

`tsx-layout-check FILE` reports the same errors. It also reports a card that the app leaves out, so an editor can refuse it. A warning (an unknown key, an icon that is not in the font) does not stop the app.

`tsx-layout-check --install SRC DEST` checks `SRC` and installs it as `DEST`. The setup page uses it, through the helper of the setup page, to save a layout (see [Layout](layout.md)). The tool trusts nothing about `SRC`. It opens `SRC` with `O_NOFOLLOW` and refuses a file that is not a regular file or that has more than 65536 bytes. It refuses a layout with an error and prints each error on its own line. It installs the bytes that it checked, with no new serialization. It writes a temporary file in the folder of `DEST` (mode 644), calls `fsync`, renames the file and calls `fsync` on the folder. `DEST` stays as it was after every refusal.

## The layout editor

The layout editor is a page of the setup page. You can use it on a phone or on a PC. It needs no other software on the panel and no access to Home Assistant.

### Open the editor

1. Open the setup page of the panel (see [Layout](layout.md#setup-page-without-a-kiosk)). On the screen of the panel, the setup page is the loopback address. From a phone or a PC, use `http://ADDRESS:PORT/setup`. The panel allows this only while it is not configured, or for 15 minutes after `tsx-config setup`.
2. Enter the pairing code that the screen shows, if the page asks for it.
3. Tap "Edit the layout of the screen". The editor is at `/setup/layout`. It has the same rules for access as the setup page.

### What the editor edits

The editor edits the layout file in the format that this page describes. It shows the layout of the user (`/var/lib/tsx/panel-layout.json`). When the user has no file, it shows the default layout of the board (`/etc/tsx/panel-layout.json`), and then the example layout. The first save makes the file of the user.

| Part | What you can do |
|---|---|
| Pages | Add, remove, rename and move a page. Set the columns and the rows of a page. |
| Grid | Set the default columns, rows and gap. |
| Cards | A preview of the grid shows the cards in the cells where the app places them. Add, remove and move a card in the list. Tap an empty cell to move the selected card there. |
| One card | The type, the entity id, the label, the icon (a search in `icons.txt`), the size, the cell (empty means automatic), the tap action, the hold action and the keys of the type. A `climate` card has the field `step`. A `slider` card has the fields orientation, send, minimum, maximum and unit (with "Show no unit"). |
| Conditional card | The entity of the condition, the choice "state" or "state_not", the states, and the inner card. The states are one text field with commas. The editor saves one state as a text and more states as a list. The inner card has a type, an entity id, a label, an icon, a tap action, a hold action and the keys of its type. |
| Theme | The five colors. Each color can use the default. |
| Keys | One row for each of `home`, `up`, `down`, `power` and `lights`, and a row for each other key. The list shows the default of the key. A key can use the default, do nothing, show page N, or show the next or the previous page. It can also open the setup window, open the settings overlay, turn the panel lights on or off, turn the screen off, or send a Home Assistant action. |
| Raw JSON | The text of the layout. Edit it and tap "Use this JSON". |

The editor changes only the parts that you change. A key that it does not know stays in the file. An empty field removes its key from the file.

The editor sends the layout to the panel for a check after each change. The check uses the same rules as `tsx-layout-check`. The editor shows the errors and the warnings at the top and next to the card. It also shows a card that the app leaves out, because an error or an overlap stops the card. "Save" is possible with a warning. The panel refuses a layout with an error.

"Revert" loads the layout again and drops your changes. When you have unsaved changes, the button asks for a second tap.

### The key action setup

The action `"setup"` is for the entries of `keys`. When the user presses the key, the app runs `tsx-config setup`. This opens the setup window of the panel for 15 minutes, as the entry "Setup" of the overlay does. A tap on a card cannot use it.

### The save path

1. The editor sends the layout and the revision that it loaded to `POST /setup/api/layout/save`. The revision is the SHA-256 hash of the file of the user, or an empty text when the file does not exist.
2. `tsx-setupd` refuses the save with the status 409 when the file changed after the page loaded. Then it saves nothing.
3. `tsx-setupd` checks the layout. It refuses a layout with an error.
4. `tsx-setupd` writes the layout (JSON with 2 spaces and UTF-8 text, with the order of the keys of the editor) to `/run/tsx-setup/layout.new` with mode 600.
5. `tsx-setupd` sends the command `layout-save` to `tsx-setup-helper`. The helper runs `tsx-layout-check --install` as root. The tool checks the file again and installs it atomically in `/var/lib/tsx/panel-layout.json` with mode 644.
6. The app sees the new file and shows it after a few seconds (see "Reload").

`tsx-setupd` does not run as root. It never writes the layout file itself.

### Entity picker

The panel has no general access to Home Assistant, and the editor must not change anything in Home Assistant. So the editor uses three sources for the list of entities. The user can also type any entity id.

| Source | What it gives | Needs |
|---|---|---|
| The layout | The entity ids that the layout uses. | Nothing. |
| The app | The entities that the app knows, with name and state. The app writes `/run/tsx/panel-app/entities.json`: `{"uptime": 1234, "entities": [{"entity_id": "light.kitchen", "name": "Kitchen", "state": "on"}]}`. The file is missing when the app does not run. Then the list is empty. | The app. |
| The full list (optional) | All entities of Home Assistant, with name and state. | A URL and a token, once. |

The editor checks an entity id with the same rule as the checker (`domain.name`). A card of a type with its own domain (for example `light` or `cover`) needs an entity of that domain. The field shows the name and the state of a known entity.

For the full list, the user enters the URL of Home Assistant and a long-lived access token in the section "Home Assistant entity list". The token has these rules:

- `tsx-setupd` sends the token to `tsx-setup-helper` (`ha-token-set`). The helper stores it as root in `/var/lib/tsx/panel-app/ha-token` (mode 600, two lines: the URL and the token). `tsx-setupd` does not keep it and does not log it.
- The helper command `ha-entities` runs `tsx-ha-entities` as root. The tool sends `GET URL/api/states` with the token. It has a time limit of 10 s. It follows a redirect only to the same scheme, host and port. It writes `[{"entity_id": ..., "name": ..., "state": ...}]` to `/run/tsx/panel-app/ha-entities.json` (mode 640, group `tsx-setup`).
- The page never gets the token back. It shows only "A token is stored". "Remove the token" (`ha-token-clear`) deletes the token and the list.
- The panel reads from Home Assistant. It changes nothing there. The panel does not trust a certificate that it cannot check. For a Home Assistant with a private certificate, use the http address.

The reasons for this design:

- A browser in the user's network cannot read the entities of Home Assistant because of the same-origin rule. A browser-only list would need a token in the browser.
- A token with a long life is a secret. Only root keeps it, and only as a file with mode 600. The unprivileged process of the setup page never has it.
- The full list is optional. The editor works with the first two sources and a typed entity id.

### The API encryption key

The setup page has the field "API encryption key" (`HA_API_KEY` of `panel.conf`). It is the key for the ESPHome API of the app. The key is a secret. The page never shows the stored key. It shows only that a key is set. A blank field keeps the stored key.

"Make a new key" makes 32 random bytes with `crypto.getRandomValues` in the browser and shows the base64 text in the field. To give the key to Home Assistant:

1. Copy the key.
2. In Home Assistant, open Settings, then Devices & services.
3. Open the ESPHome device of the panel.
4. Enter the key as the encryption key.

Home Assistant and the panel need the same key. `tsx-config` checks the format when the page saves it. The plugin adds the field only when no other plugin in `setup.d` names `HA_API_KEY`.

## Screen

The app controls the backlight of the panel (the first folder in `/sys/class/backlight`, or the `backlight` setting).

- The brightness is a percent of the slider, 1 to 100. On a backlight with more than 64 steps, the slider maps to the steps with a square, as the slider of the kiosk overlay does. So the dark end has finer steps. `BACKLIGHT_MIN` and `BACKLIGHT_MAX` of `/etc/tsx/panel-board.conf` set the lowest lit level and the highest level.
- The app keeps the brightness in `ESPHOME_PREFDIR/backlight` (`/var/lib/tsx/panel-app/backlight`). Before the first change, the app keeps the level that the panel has at the start.
- After `dim_timeout` with no touch and no key, the backlight goes to the dim level. After `blank_timeout`, the backlight goes off and the app runs `on_screen` with `on` false. A board can make the display dark there (for example the `set_power` of `tsx_drm`, with a black frame or with the output off). Then the glass shows no picture in room light.
- A touch or a key wakes the screen. While the screen is dim or off, a transparent object on the top layer takes the touch. It stays until the finger lifts and for 120 ms after the last touch report. So the touch that wakes the screen does not tap a card and does not change the page. A key that wakes the screen does no action and sends no event.
- With `input_id`, the first report of a touch wakes the screen at once, in the loop of `tsx_evdev`. LVGL does not have to read the touch first. So a very short tap also wakes the screen.
- The wake has a fixed order. First the CPU goes to full speed (see "CPU speed"). Then the app runs `on_screen` with `on` true: the display puts the full picture on the output and waits for the flip. Then the backlight comes on. So the glass shows no old, black or white frame with the backlight on.
- A five-finger tap or a key opens the settings overlay only while the screen is on.
- The app writes the screen state to `/run/tsx-idled.state`, in the format of `tsx-idled`: `on LEVEL` while the screen is on or dim, `blank` while it is off. `tsx-autoupdate` installs only while the screen is off. The app also writes `/run/tsx/panel-app.state` (the process, the first frame and the Home Assistant connection) for the health check after an update reboot. See [autoupdate.md](autoupdate.md). An app that runs as the user `tsx-panel-app` writes these files in `/run/tsx/panel-app/app`, and the two paths are links to them (see "Service").

The times and the dim level come from these places. A later place wins:

| Setting | Default of the app | YAML | `panel.conf` key | Run-time file |
|---|---|---|---|---|
| Dim after | 60 s | `dim_timeout` | `DIM_TIMEOUT` | `/run/tsx/dim-timeout` |
| Off after | 300 s | `blank_timeout` | `BLANK_TIMEOUT` | `/run/tsx/blank-timeout` |
| Dim level | 30 % | `dim_level` | `DIM_LEVEL` | `/run/tsx/dim-level` |

0 s means never. `BLANK_TIMEOUT` is the key that the kiosk panels use for `tsx-idled`. `tsx-config apply` writes the run-time files from `panel.conf`. The plugin `/usr/local/lib/tsx/config.d/panel_app.sh` adds the keys `DIM_TIMEOUT` (0 to 86400) and `DIM_LEVEL` (1 to 100) to `tsx-config`. The app reads the files every 5 s.

When you change a time in the overlay or in Home Assistant, the app uses the new value at once. After 2 s it runs `tsx-config set` and `tsx-config apply`, so `panel.conf` keeps the value. An app that does not run as root sends `blank-timeout`, `dim-timeout` or `dim-level` to `tsx-panelctl` instead, and `tsx-panelctl` runs the two commands. For 30 s after a change, the app does not read the run-time files.

The app has these Home Assistant entities for the screen. Home Assistant can change them, also when the device setting "Allow the device to perform Home Assistant actions" is off. That setting is only for the actions that the app sends.

| Entity | Type | Function |
|---|---|---|
| Screen | switch | On while the screen is on or dim. Off turns the screen off. On wakes it. |
| Backlight | number, 1 to 100 % | The brightness of the slider. |
| Blank timeout | number, s | `BLANK_TIMEOUT`. |
| Dim timeout | number, s | `DIM_TIMEOUT`. |
| Dim level | number, 1 to 100 % | `DIM_LEVEL`. |
| Volume | number, 0 to 100 % | The volume of the panel (see "Volume"). Unknown on a panel with no sound card. |
| Layout hash | text sensor | The SHA-256 of the layout file in use (see "Layout from Home Assistant"). |

The names and the units are the same as on the kiosk panels. See "Panel settings" in [esphome.md](esphome.md). The entities for the updates are in "Updates".

The app reads the values of these entities every 1 s to 10 s. It sends a value to Home Assistant only when it changed (`tsx_cards::if_changed()` in the lambdas of `panel-app.yaml`). Each send is a message on the API connection. So an idle panel sends no message.

## Control from the panel

The setup page and other services of the panel change the screen and the lights of the app through `tsx-panelctl`, as on a kiosk panel. `tsx-panelctl has panel-app` is true while the app runs (`/run/tsx/panel-app.state` names a process that exists). Then the daemon of `tsx-panelctl` hands these commands to the app:

| `tsx-panelctl send` | Line for the app |
|---|---|
| `blank on`, `blank off` | `screen off`, `screen on` |
| `brightness-pct P` | `backlight P` (1 to 100) |
| `lights on`, `lights off` | `lights on`, `lights off` |
| `lights set B R G BL` | `lights B R G BL` (brightness 1 to 100, color 0 to 255) |

The daemon writes one file for each command into `/run/tsx/panel-app/control.d`: a temporary file in `/run/tsx`, then a rename. When the app runs as root, only root can write the folder. When the app runs as `tsx-panel-app`, that user owns the folder, and root owns the folder above it (see [security.md](security.md)). The app reads the folder twice a second. It runs the lines in the order of the file names, removes each file and refuses every other line (log line `control: refused`). The code is `control.h` and `control.cpp` of `tsx_cards`.

The app writes its values to `/run/tsx/panel-app/screen.state` (mode 644) when a value changes:

```
screen on
backlight 64
dim-timeout 60
blank-timeout 300
dim-level 20
lights off 80 255 128 0
```

`screen` is `on`, `dim` or `off`. The `lights` line is there only with `panel_lights`: on or off, the brightness and the color of the first light. `tsx-panelctl get backlight-pct`, `get lights`, `get dim-timeout` and `tsx-panelctl state` read this file. The times go to `panel.conf` as before (`tsx-panelctl send dim-timeout`, `dim-level` and `blank-timeout` run `tsx-config set` and `apply`).

## Layout from Home Assistant

The app has two Home Assistant actions. Home Assistant names them `esphome.<device>_set_layout` and `esphome.<device>_get_layout`.

| Action | Data | Answer |
|---|---|---|
| `set_layout` | `layout`: the JSON text of a layout file | Success or the first error |
| `get_layout` | none | `layout` (the parsed layout), `hash`, `source` (the file in use), `status` (the result of the last `set_layout`) |

`set_layout` does these steps:

1. The app checks the text with its own rules (`parse_layout`, at most 65536 bytes). An error goes back at once as the error of the action.
2. The app writes the text to `layout.ha` (mode 600) in `/run/tsx/panel-app`, or in `/run/tsx/panel-app/app` when it runs as `tsx-panel-app`.
3. The app runs `tsx-layout-check --install` on it, as a child process. The tool checks the text again with the same rules and the icon list. It installs the file atomically as the first layout file (`/var/lib/tsx/panel-layout.json`). An app that does not run as root cannot write that folder. It sends `layout-install ID` to `tsx-panelctl`, which runs the same command as root and writes the result to `/run/tsx/panel-app/layout.result`. The app waits for the result of its ID, at most 30 s.
4. The app reads the new file and makes the pages again (see "Reload").

The result of step 3 is the `status` of `get_layout`: `saved` or `error: TEXT`. While one `set_layout` runs, a second one gets an error. The file of the user stays after a reboot, as a save of the layout editor does. Example of a call from a Home Assistant script (the device name is `hall-panel`):

```yaml
action: esphome.hall_panel_set_layout
data:
  layout: >-
    {"version": 1, "pages": [{"name": "Home",
     "cards": [{"type": "light", "entity_id": "light.kitchen"}]}]}
```

The "Layout hash" sensor shows the SHA-256 of the layout file in use. `sha256sum /var/lib/tsx/panel-layout.json` on the panel gives the same text. An automation can compare it after a `set_layout`.

Use `set_layout` only from a Home Assistant that the panel trusts: set the API encryption key (see "Identity and API key").

## CPU speed

A UI draws in short bursts. A load governor such as `ondemand` sees the load of a burst only after its sample time. So the first frames of a page change run at a low clock. The app can set the frequency limits of the CPU itself. Two keys of `/etc/tsx/panel-board.conf` turn this on:

| Key | Meaning |
|---|---|
| `CPUFREQ_BOOST_MS` | After each touch report, key press, redraw burst (two frames within 100 ms) and wake, the app sets `scaling_min_freq` to the highest frequency for this time. Then it sets the lowest frequency again, and the governor scales the CPU down. 0 or no key: no boost. |
| `CPUFREQ_SCREEN_OFF` | `lowest`: while the screen is off, the app sets `scaling_max_freq` to the lowest frequency. While a sound card plays, it keeps the full range (see below). At the wake it sets the full range again, before the picture. `keep` or no key: the full range. |

Audio at the lowest frequency can stutter, for example Sendspin or a voice answer while the screen is off. So with `CPUFREQ_SCREEN_OFF=lowest`, the app checks the playback streams of the sound cards once a second while the screen is off. A stream plays when its file `/proc/asound/cardN/pcmMp/subK/status` has the line `state: RUNNING` or `state: DRAINING`. While a stream plays, the app sets the full range and the governor is free. One second after the last stream stops, the app sets the lowest frequency again. The log has a line for each change (`audio plays` or `no audio`). `TSX_ASOUND_DIR` replaces `/proc/asound` for tests.

The app writes only the two limits of each policy in `/sys/devices/system/cpu/cpufreq` (`TSX_CPUFREQ_SYS` replaces this folder for tests). For an app that runs as `tsx-panel-app`, the service gives the group of that user write access to the two files before the start. It writes the full range (`cpuinfo_min_freq` to `cpuinfo_max_freq`) at the start and at the end. The board sets the governor and its settings, for example in a boot service. A write that changes the frequency also changes the core voltage. On a single-core ARM CPU, such a write can take 2 to 10 ms.

## Settings overlay

A tap with five fingers opens the settings overlay, as on the kiosk panels. The key action `"overlay"` also opens it (the default of the key `power`). A tap with two fingers or more never taps a card.

The overlay has these items:

| Item | Function |
|---|---|
| Brightness slider | Sets the backlight. On a panel with a light sensor (`LIGHT=yes` or `ALS=yes` in `/run/tsx/hw.conf`), the row "Auto brightness: off" under the slider tells that the app does not change the backlight from the sensor. On a panel with no light sensor, the overlay has no such row. |
| Volume slider | Sets the volume of the panel (see "Volume"). Only a panel with a volume has it. While the Sendspin player runs, a tap on the volume icon mutes or unmutes the player. The icon then shows the mute, and the text under the slider says "Muted". |
| Dim after, Screen off after | The times of the screen, with - and + buttons. The steps are Never, 15 s, 30 s, 1 min, 2 min, 5 min, 10 min, 15 min, 30 min, 1 h and 2 h. |
| Screen off | Turns the screen off at once. |
| Lights | Turns the panel lights on or off (see "Panel lights"). The button has the `card_on` color while a light is on. A board with no panel lights has no button. |
| Open setup | Runs `tsx-config setup` and closes the overlay. The setup banner shows the address and the pairing code (see "Setup banner"). |
| Reboot | Asks "Reboot the panel now?". "Reboot" runs `reboot` (an app that does not run as root sends `reboot` to `tsx-panelctl`), "Cancel" closes the question. |
| Facts | The address, the host name, the Home Assistant connection, the device name and the versions of the panel app packages. |
| Close | Closes the overlay. |

A tap outside the overlay closes it. The overlay also closes after `overlay_timeout` (10 s) with no touch. The item "Reload page" of the kiosk overlay is for a browser. The app does not have it.

Test hooks: `TSX_PANEL_APP_REBOOT_CMD` replaces `reboot`, `TSX_PANEL_APP_CONFIG_CMD` replaces `tsx-config`, `TSX_RUN_DIR` replaces `/run/tsx`, `TSX_BACKLIGHT_DIR` replaces the backlight folder, `TSX_PANEL_BOARD_CONF` replaces `/etc/tsx/panel-board.conf`.

## Volume

The panel has one volume. The setup page, `tsx-panelctl`, the Home Assistant number "Volume" and the overlay show and set the same value.

While the Sendspin player runs, the volume of the panel is the player volume of Music Assistant (see [sendspin.md](sendspin.md), "Audio and volume"). The player writes its volume and mute to `/run/sendspin-cli/volume` at each change (`TSX_PANEL_APP_SENDSPIN_VOLUME` names another file). The app reads that file. A change in Music Assistant shows in the overlay and in the number "Volume" within about a second.

The app sends a change to `tsx-panelctl` (`volume N`, `mute on|off`), which sets the player. A drag of the slider sends at most four values per second, and always the last one. After a change, the app shows the new value until the player reports it, for at most 3 s. A program that runs as root uses the same FIFO.

Without that file, the volume of the panel is one mixer control of the sound card: `Master`, the softvol of the board in `/etc/asound.conf`. The app reads and writes the control with the control ioctls of the kernel, as a member of the group `audio`. It needs no alsa-lib. `tsx-panel-app-run` gives the app the card of the board (`TSX_SOUND_CARD` of `board.sh`) as `TSX_PANEL_APP_SOUND_CARD`. `TSX_PANEL_APP_VOLUME_CTL` names another control. The percent is the position in the range of the control: for the softvol of `Master` with 101 steps, the percent is the raw value.

With no player, no card and no control, the Volume number is unknown and the overlay has no volume slider. The app tries to open the control again every 10 s, because the board makes the softvol at boot.

## Updates

The app shows the state of `tsx-autoupdate` as Home Assistant entities. They are the same as on the kiosk panels (see [autoupdate.md](autoupdate.md)).

| Entity | Type | Function |
|---|---|---|
| Update | update | The running release (installed) and the release in the index (latest), with the title and the summary. Install updates the panel at once. |
| Restart required | binary sensor | On after an install that needs a restart, until the panel restarts. |
| Restart | button | Restarts the panel. The class of the button is `restart`. |
| Update mode | select | `auto` or `manual`. In `auto`, the panel installs updates by itself. In `manual`, it only shows that an update is available. |
| Automatic restart | switch | On: the panel restarts after an install that needs a restart. Off: Home Assistant shows "Restart required". |

The select and the switch are in the entity category `config`.

The state comes from the file `/run/tsx/update.state` that `tsx-autoupdate` writes (`TSX_PANEL_APP_UPDATE_STATE` names another file). The file has one `key value` pair on each line: `installed`, `latest`, `title`, `summary`, `in-progress`, `restart-required`, `mode` and `auto-restart`. The summary is Markdown text on one line. The two characters `\n` are a newline and `\\` is a backslash. Home Assistant shows it as the release notes. The app reads the file at most every 3 s. While a change waits for the file, the app reads it every second.

The entity "Update" has one of these states:

| State | When |
|---|---|
| Unknown | The file does not exist, or `installed` is `unknown`. |
| Installing | `in-progress` is `yes`. |
| Update available | `latest` is not the same as `installed`. |
| No update | In all other cases. |

After an install that needs a restart, `installed` stays the running release and `latest` is the new release with the text "(restart required)". The title is "Restart required to finish" and the new release. So the entity stays in the list of updates, the title and the latest version show the new state, and Install restarts the panel. See "What Home Assistant shows" in [autoupdate.md](autoupdate.md).

The app does not run as root. Each action is one line on the FIFO of `tsx-panelctl`:

| Entity | Line |
|---|---|
| Update, Install | `update-install` |
| Restart | `reboot` |
| Update mode | `update-mode auto` or `update-mode manual` |
| Automatic restart | `auto-restart on` or `auto-restart off` |

`tsx-panelctl` keeps the two settings in `panel.conf` (`UPDATE_MODE` and `UPDATE_AUTO_RESTART`) with `tsx-config`. After a set, the app shows the new value at once. It holds the value until the file shows it, for at most 10 s. The file changes about 3 s after a set, because `tsx-config apply` runs first. After an Install, the entity shows "Installing" in the same way. The app never taps the screen for these actions.

## Panel lights

A board can give the app the lights of the panel (`panel_lights`, ESPHome light ids). The key action `"lights"` and the overlay button turn them on or off. When one light is on, both go off. Else all lights go on with their last color and brightness. This is a local action. It sends nothing to Home Assistant.

The light platform `tsx_leds` makes an ESPHome light from a Linux LED device in `/sys/class/leds`. A multicolor LED device (with `multi_index`) is an RGB light. The platform writes `multi_intensity` with the color and the brightness, and then `brightness`. A device with one color is a light with a brightness only. Use `restore_mode: ALWAYS_OFF`, so the lights are off after each start. Home Assistant sees each light as a light entity of the device and can change it.

## Key events

A board sends each key change to the app with `key_state("NAME", x)`. The app then does this:

1. A press while the screen is dim or off only wakes the screen.
2. Else the press runs the action of the key at once (see "Keys").
3. The ESPHome event entity of the key (`key_events`) gets the event type `press` when the user releases the key. It gets `long` when the user holds the key for 0.8 s.

The event entities have the names and the event types of the key events of the kiosk panels (for example "Key power"). A Home Assistant automation can use them with the trigger "Entity state" or the event trigger of the entity. `key_press("NAME")` runs only the action of the key, with no wake and no event.

## Home Assistant states

The app subscribes to the states that its cards need, through the ESPHome API:

| Card | States |
|---|---|
| all but `clock` | The state of the entity. `friendly_name` when the card has no `label`. |
| `light` | `brightness` |
| `sensor` | `unit_of_measurement` when the card has no `unit` and no `attribute`. The attribute of the card. |
| `weather` | `temperature`, `temperature_unit`, `humidity` |
| `cover` | `current_position` |
| `climate` | `current_temperature`, `temperature`, `target_temp_step`, `hvac_modes` |
| `media_player` | `media_title`, `media_artist`, `volume_level` |
| `fan` | `percentage` |
| `conditional` | The state of its entity, and the states of the inner card |

The ESPHome API cannot remove a subscription. So a subscription stays until the program stops, also when a new layout does not use it. Home Assistant reads the list of subscriptions only when it connects. When a new layout adds an entity while Home Assistant is connected, the app closes the API connection. Home Assistant connects again and reads the full list. Until then, the page bar shows "Not connected" and the new cards show `--`.

## Reload

The app watches the folders of the layout files with inotify. It also checks the file every 2 s, for a folder that did not exist at the start. When the content of the file changes, the app makes all pages again. It keeps the shown page and the last values of the entities, so the new cards show their values at once.

## Log lines

The app writes the times of the start and of a reload to the log, with the tag `perf`:

| Line | Meaning |
|---|---|
| `first frame` | The time from the process start to the first frame on the screen. |
| `Home Assistant connected` | The time from the process start to the API connection. |
| `first entity value`, `all entity states` | The time to the first state and to the state of each entity of the layout. |
| `layout read and parse`, `build` | The time to read and parse the file and to make the LVGL objects. |
| `layout reload` | The time from the file read to the new frame. |
| `page change` | The time from a page change to the new frame. |
| `wake (ORIGIN)` | The time from the input event (or from the wake call) to the backlight on, with the parts: to the wake, the CPU limits, and the picture on the output. |
| `last 60 s` | The frames that LVGL drew in the last minute, and their average render time. A screen with no change draws no frame. |
| `slider drag on page P card C` | The frames that LVGL drew while the finger was on a slider, the time of the touch, the average and the largest render time, and the number of actions that the slider sent. |

A tap or a key press writes a line with the tag `tsx_cards`, for example `tap on page 1 card 3 (light light.kitchen): action light.toggle`.

## Icons

The icons come from Material Design Icons (Pictogrammers, Apache License 2.0). The build downloads the font file and keeps only the glyphs of `icon-glyphs.yaml`. To add an icon:

1. Add its name and code point to `icons.txt`.
2. Run `panel-app/esphome/mkicons.py`.
3. Commit `icons.txt`, `icons.h` and `icon-glyphs.yaml`.

`tests/test-panel-layout.sh` fails when `icons.h` or `icon-glyphs.yaml` is out of date.

## Identity and API key

Home Assistant knows the panel app as one ESPHome device. The device has a name, a friendly name, a MAC (the unique id in Home Assistant) and an API encryption key. Each panel needs its own values, but the program is the same on all panels of a family. So the program gets the values at start:

| Value | Source | Read by |
|---|---|---|
| Device name | `TSX_PANEL_APP_NAME` (environment) | `tsx_runtime` |
| Friendly name | `TSX_PANEL_APP_FRIENDLY_NAME` (environment) | `tsx_runtime` |
| MAC | `TSX_PANEL_APP_MAC` (environment, `aa:bb:cc:dd:ee:ff`) | `host-mac.patch` |
| API encryption key | `/run/tsx/esphome.key` (setting `key_file`) | `tsx_runtime` |

Without a value in the environment, the value of the YAML stays.

`tsx-config apply` writes `/run/tsx/esphome.key` from the key `HA_API_KEY` of `panel.conf`. The key is 32 random bytes in base64, the same text as `api: encryption: key:` of ESPHome. Give the same key to Home Assistant when you add the device. `tsx_runtime` checks the file every 5 s. When the key changes, the program uses the new key at once and closes the open API connections. Home Assistant then connects again with its key. The program never writes the key to the log.

Without a valid key file, the program uses a random key. Then no client can connect, and the log tells why. The program never runs the API with no encryption. The YAML must give `api: encryption: key:`, but only as a placeholder: it makes ESPHome build the encrypted API with no plaintext fallback. `tsx_runtime` replaces the placeholder before the API starts.

## Service

The service `tsx-panel-app` runs `tsx-panel-app-run`, which starts the program. The script reads three files. A later file wins:

| File | Package | Contents |
|---|---|---|
| `/etc/tsx/panel-app.conf` | the panel app | The defaults: the program, the folder of the ESPHome preferences (`/var/lib/tsx/panel-app`), the network interface of the MAC (`eth0`). |
| `/etc/tsx/panel-app-board.conf` | the board | `PANEL_APP_ENV` (the environment of the program, for example the SDL video driver), `PANEL_APP_DIRS` (folders that the script makes with mode 700), `PANEL_APP_DEVICES` (device files that the script waits for, at most `PANEL_APP_WAIT` seconds). |
| `/var/lib/tsx/panel-app.conf` | none (the panel) | `NAME`, `FRIENDLY_NAME` and `MAC` of this panel. |

At the first start, the script finds the identity and writes it to `/var/lib/tsx/panel-app.conf`:

- `NAME`: the host name in lowercase. A character that is not a letter, a digit or `-` becomes `-`. The name has at most 31 characters.
- `FRIENDLY_NAME`: the host name.
- `MAC`: the MAC of `eth0` with the locally administered bit set and the multicast bit clear.

Later starts use the saved values. So a new host name does not make a new device in Home Assistant. To give the panel other values, edit the file and restart the service. `/var/lib/tsx` keeps its contents after an image update, so the device stays the same.

`tsx-panel-app-run --print` shows the values and starts nothing. The log of the program is `/var/log/tsx-panel-app.log`.

### The user of the program

The program runs as the user `tsx-panel-app` (the package makes it) when the program can do so: the program has the text `TSX_PANEL_APP_OUT_DIR`. An older program runs as root. `PANEL_APP_USER` of `/etc/tsx/panel-app.conf` changes the choice: empty is the choice above, `root` is always root. `tsx-panel-app-run --user` prints the user. [security.md](security.md) lists the groups and the root helper.

Before each start, the service runs `tsx-panel-app-run --prepare` as root. It does these steps:

1. It saves the identity (see above).
2. It moves the ESPHome preferences from `PANEL_APP_PREFDIR` to `PANEL_APP_PREFDIR/app` (mode 700, owned by the user) once. The program gets this folder as `ESPHOME_PREFDIR`. `PANEL_APP_PREFDIR` gets mode 711. Root keeps the token of the layout editor there.
3. It makes `/run/tsx/panel-app/app` and `/run/tsx/panel-app/control.d` for the user. `/run/tsx/panel-app` stays a folder of root.
4. It makes `/run/tsx-idled.state`, `/run/tsx/panel-app.state`, `/run/tsx/panel-app/screen.state` and `/run/tsx/panel-app/entities.json` links to the files of the program in `/run/tsx/panel-app/app`. The program gets this folder as `TSX_PANEL_APP_OUT_DIR`.
5. It gives the folders of `PANEL_APP_DIRS` to the user.
6. For a user that is not root: it gives the group of the user write access to `scaling_min_freq` and `scaling_max_freq` of each CPU policy, and to `brightness` and `multi_intensity` of the LEDs of `PANEL_APP_LEDS` (shell patterns of names in `/sys/class/leds`, the board sets them).

A program that does not run as root gets `TSX_PANEL_APP_PANELCTL`, the FIFO of `tsx-panelctl`. It sends the actions that need root there: `reboot`, `setup`, `blank-timeout`, `dim-timeout`, `dim-level`, `layout-install`, `update-install`, `update-mode` and `auto-restart`.

## Setup banner

While the pairing code of the setup page works, `tsx-setupd` writes `/run/tsx-setup/screen.json` with the pairing code, the port and the addresses of the panel. The file has the group `tsx-setup-screen` and mode 640, so the app as `tsx-panel-app` can read it. The app checks the file every 2 s. While the file is less than 30 s old, the app shows a bar at the top of the screen: `Setup: http://ADDRESS:PORT/setup    Code: CODE`. The bar takes no touch: a tap goes to the card below it. The log tells only that the bar is on or off. It never has the code.

The key action `"setup"` runs `tsx-config setup` (an app that does not run as root sends `setup` to `tsx-panelctl`). That command opens the window for about 15 minutes (see [setup.md](setup.md)). An administrator of Home Assistant needs no code: see "Log in with Home Assistant" in [setup.md](setup.md). The environment variable `TSX_PANEL_APP_SETUP_CMD` replaces the command for a test.

## Entity list

The app writes `/run/tsx/panel-app/entities.json` (a link to `/run/tsx/panel-app/app/entities.json` for an app that runs as `tsx-panel-app`) at most every 2 s, after a state changes or after a reload. The layout editor of the setup page reads it. The file has the entities of the layout and their last states:

```json
{"uptime": 3351, "entities": [{"entity_id": "light.kitchen", "name": "Kitchen", "state": "on"}]}
```

`name` is the friendly name of the entity when the app subscribed to it, else the label of a card. `state` is `null` before Home Assistant sends the state. `uptime` is the seconds since the boot at the write.
