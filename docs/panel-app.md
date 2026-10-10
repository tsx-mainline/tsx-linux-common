# Panel app

Status: experimental. The layout format and the component settings can change in a later release. The xx60 boards use the browser kiosk and do not ship the program. A board that uses the app ships the program in its own package.

The panel app shows Home Assistant cards on the panel screen with no browser. It is an ESPHome program for Linux (the ESPHome `host` platform) with an LVGL screen. The cards come from a JSON layout file. The app reads the file when it starts and again when the file changes. A change of the layout needs no new build and no restart.

The app is one ESPHome device in Home Assistant. It reads the states of the entities in the layout and sends the action of a card when you tap it.

The panel app is a test. No package installs it yet.

## Parts

| Path | Contents |
|---|---|
| `panel-app/esphome/components/tsx_cards/` | The ESPHome component `tsx_cards` (C++). It reads the layout, makes the pages and cards, subscribes to the states and sends the actions. |
| `panel-app/esphome/panel-app.yaml` | The generic part of the ESPHome configuration: the API, the Home Assistant time, the icon font, LVGL and `tsx_cards`. A board includes it as a package. |
| `panel-app/esphome/icon-glyphs.yaml` | The glyph list of the icon font. `mkicons.py` writes it. |
| `panel-app/esphome/mkicons.py` | Writes `icons.h` and `icon-glyphs.yaml` from `icons.txt`. `--check` tells if they are out of date. |
| `panel-app/usr/local/bin/tsx-layout-check` | Checks a layout file with the same rules as the app. |
| `panel-app/usr/local/share/tsx/panel-app/icons.txt` | The icons of the app: the MDI name and the code point. |
| `panel-app/usr/local/share/tsx/panel-app/example-layout.json` | An example layout with made-up entities. |
| `panel-app/usr/local/share/tsx/panel-app/layout.schema.json` | A JSON schema of the layout format, for editors. |

## The board part

A board gives the parts that the generic YAML does not know. The board YAML does these things:

1. It sets `esphome: name` and `friendly_name`, and the platform (for example `host:`).
2. It includes `panel-app.yaml` with `packages:` and the component with `external_components:`.
3. It makes a display with the id `panel_display` and a touchscreen with the id `panel_touch`.
4. It sends each key of the panel to the app: `id(panel_cards).key_press("NAME")`. Use the key names of `buttons-board.conf` (for example `home`, `up`, `down`). A key that is a binary sensor needs `trigger_on_initial_state: true`. Without it, ESPHome ignores the first press after the start.
5. It gives `api_key` (the API encryption key) in `secrets.yaml`.

The board also builds the program and starts it as a service. The board docs tell how.

## Component settings

| Setting | Default | Meaning |
|---|---|---|
| `layout_files` | `/var/lib/tsx/panel-layout.json`, `/etc/tsx/panel-layout.json` | The layout files, in order. The app uses the first file that exists. The environment variable `TSX_PANEL_LAYOUT` adds a file in front of the list. |
| `time_id` | none | The time component for the clock cards. Without it, a clock card shows `--:--`. |
| `page_bar_height` | 36 | The height of the page bar at the bottom of the screen, in pixels. 0 removes the bar. |
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
| `type` | all | `light`, `switch`, `scene`, `script`, `sensor`, `weather` or `clock`. Required. |
| `entity_id` | all but `clock` | The Home Assistant entity. Required. A `light`, `scene`, `script` or `weather` card needs an entity of that domain. |
| `label` | all | The name on the card. Default: the friendly name of the entity. |
| `icon` | all but `clock` | An icon as `"mdi:name"`. The name must be in `icons.txt`. Default: an icon for the type and the state. |
| `w`, `h` | all | The size in cells. Default 1. |
| `x`, `y` | all | The cell of the top left corner, from 0. Give both or none. |
| `tap` | all | The action of a tap. See "Actions". Default: the action of the type. |
| `attribute` | `sensor` | Show this attribute of the entity, not its state. |
| `unit` | `sensor` | The unit text. Default: the `unit_of_measurement` of the entity. |
| `precision` | `sensor` | The number of decimals of a numeric value (0 to 6). Default: the value as Home Assistant sends it. |
| `format` | `clock` | The format of the time (strftime). Default `%H:%M`. |
| `date_format` | `clock` | The format of the date (strftime). Default `%a %d %b`. An empty text removes the date. |

The card types:

| Type | Shows | Default tap |
|---|---|---|
| `light` | On with the brightness in percent, or Off. The card has the `card_on` color when the light is on. | `light.toggle` |
| `switch` | On or Off. For a `switch`, `input_boolean`, `fan` or other entity that has the action `toggle`. | `DOMAIN.toggle` |
| `scene` | A run button. | `scene.turn_on` |
| `script` | A run button. "Running" while the script runs. | `script.turn_on` |
| `sensor` | The state (or an attribute) and the unit. | none |
| `weather` | The condition, the temperature and the humidity. | none |
| `clock` | The local time and date from Home Assistant. | none |

A value that is not known yet shows `--`.

### Placement

The app gives each card its cells in two steps:

1. The cards with `x` and `y` get their cells, in the order of the list.
2. The other cards get the first free cells, row by row, in the order of the list.

A card that overlaps an earlier card, or that has no free place, is left out.

### Actions

A `tap` value or a `keys` value is one of these:

| Value | Meaning |
|---|---|
| `"default"` | The default action of the card type (`tap` only). |
| `"none"` | Nothing. |
| `"page:N"` | Show page N, from 1 (`keys` only). |
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
| any other key | `"none"` |

### Errors

The app leaves out a card with an error and shows the other cards. The log has a line for each such card. A file that the app cannot use at all (bad JSON, no pages, a wrong `version`) does not change the screen. When the app has no usable layout yet, the screen shows the error.

`tsx-layout-check FILE` reports the same errors. It also reports a card that the app leaves out, so an editor can refuse it. A warning (an unknown key, an icon that is not in the font) does not stop the app.

## Home Assistant states

The app subscribes to the states that its cards need, through the ESPHome API:

| Card | States |
|---|---|
| all but `clock` | The state of the entity. `friendly_name` when the card has no `label`. |
| `light` | `brightness` |
| `sensor` | `unit_of_measurement` when the card has no `unit` and no `attribute`. The attribute of the card. |
| `weather` | `temperature`, `temperature_unit`, `humidity` |

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
| `last 60 s` | The frames that LVGL drew in the last minute, and their average render time. A screen with no change draws no frame. |

A tap or a key press writes a line with the tag `tsx_cards`, for example `tap on page 1 card 3 (light light.kitchen): action light.toggle`.

## Icons

The icons come from Material Design Icons (Pictogrammers, Apache License 2.0). The build downloads the font file and keeps only the glyphs of `icon-glyphs.yaml`. To add an icon:

1. Add its name and code point to `icons.txt`.
2. Run `panel-app/esphome/mkicons.py`.
3. Commit `icons.txt`, `icons.h` and `icon-glyphs.yaml`.

`tests/test-panel-layout.sh` fails when `icons.h` or `icon-glyphs.yaml` is out of date.
