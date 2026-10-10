# Panel app

Status: experimental. The layout format and the component settings can change in a later release. The xx60 boards use the browser kiosk and do not ship the program. A board that uses the app ships the program in its own package.

The panel app shows Home Assistant cards on the panel screen with no browser. It is an ESPHome program for Linux (the ESPHome `host` platform) with an LVGL screen. The cards come from a JSON layout file. The app reads the file when it starts and again when the file changes. A change of the layout needs no new build and no restart.

The app is one ESPHome device in Home Assistant. It reads the states of the entities in the layout and sends the action of a card when you tap it.

One program serves all panels of a family. The program holds no value of one panel. The service gives it the device name, the MAC and the API encryption key at start (see "Identity and API key").

## Parts

| Path | Contents |
|---|---|
| `panel-app/esphome/components/tsx_cards/` | The ESPHome component `tsx_cards` (C++). It reads the layout, makes the pages and cards, subscribes to the states and sends the actions. It also shows the setup banner and writes the entity list. |
| `panel-app/esphome/components/tsx_runtime/` | The ESPHome component `tsx_runtime` (C++). It sets the device name and the API encryption key at run time. |
| `panel-app/esphome/patches/host-mac.patch` | A patch for the `host` component of ESPHome: the MAC comes from the environment. The board build applies it to the generated project. |
| `panel-app/etc/init.d/tsx-panel-app` | The OpenRC service. |
| `panel-app/usr/local/sbin/tsx-panel-app-run` | The start script of the service: the identity, the environment of the board, then the program. |
| `panel-app/etc/tsx/panel-app.conf` | The settings of the service. |
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
2. It includes `panel-app.yaml` with `packages:` and the components `tsx_cards` and `tsx_runtime` with `external_components:`.
3. It makes a display with the id `panel_display` and a touchscreen with the id `panel_touch`. On a slow CPU, use the `tsx_drm` display and the `tsx_evdev` touchscreen and keys (see [Panel app display and input](panel-accel.md)).
4. It sends each key of the panel to the app: `id(panel_cards).key_press("NAME")`. Use the key names of `buttons-board.conf` (for example `home`, `up`, `down`). A key that is a binary sensor needs `trigger_on_initial_state: true`. Without it, ESPHome ignores the first press after the start.
5. It applies the patches of `panel-app/esphome/patches` to `src/esphome` of the generated project (`patch -p1`).

The board YAML has no value of one panel and needs no `secrets.yaml`. The board package installs the program as `/usr/local/bin/tsx-panel-app` and the file `/etc/tsx/panel-app-board.conf` (see "Service"). The board docs tell how to build it.

## Component settings

| Setting | Default | Meaning |
|---|---|---|
| `layout_files` | `/var/lib/tsx/panel-layout.json`, `/etc/tsx/panel-layout.json` | The layout files, in order. The app uses the first file that exists. The environment variable `TSX_PANEL_LAYOUT` adds a file in front of the list. |
| `time_id` | none | The time component for the clock cards. Without it, a clock card shows `--:--`. |
| `page_bar_height` | 36 | The height of the page bar at the bottom of the screen, in pixels. 0 removes the bar. |
| `setup_file` | `/run/tsx-setup/screen.json` | The file of the setup page with the pairing code (see "Setup banner"). An empty text turns the banner off. |
| `entities_file` | `/run/tsx/panel-app/entities.json` | The entity list for the layout editor (see "Entity list"). An empty text turns it off. |
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
| `"setup"` | Open the setup window of the panel: the app runs `tsx-config setup` (`keys` only). |
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

`tsx-layout-check --install SRC DEST` checks `SRC` and installs it as `DEST`. The setup page uses it, through the helper of the setup page, to save a layout (see [Layout](layout.md)). The tool trusts nothing about `SRC`. It opens `SRC` with `O_NOFOLLOW` and refuses a file that is not a regular file or that has more than 65536 bytes. It refuses a layout with an error and prints each error on its own line. It installs the bytes that it checked, with no new serialization. It writes a temporary file in the folder of `DEST` (mode 644), calls `fsync`, renames the file and calls `fsync` on the folder. `DEST` stays as it was after every refusal.

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

## Setup banner

When the network window of the setup page is open, `tsx-setupd` writes `/run/tsx-setup/screen.json` with the pairing code, the port and the addresses of the panel. The app checks the file every 2 s. While the file is less than 30 s old, the app shows a bar at the top of the screen: `Setup: http://ADDRESS:PORT/setup    Code: CODE`. The bar takes no touch: a tap goes to the card below it. The log tells only that the bar is on or off. It never has the code.

The key action `"setup"` runs `tsx-config setup`. That command opens the window for about 15 minutes (see the setup page in [Layout](layout.md)). The environment variable `TSX_PANEL_APP_SETUP_CMD` replaces the command for a test.

## Entity list

The app writes `/run/tsx/panel-app/entities.json` at most every 2 s, after a state changes or after a reload. The layout editor of the setup page reads it. The file has the entities of the layout and their last states:

```json
{"uptime": 3351, "entities": [{"entity_id": "light.kitchen", "name": "Kitchen", "state": "on"}]}
```

`name` is the friendly name of the entity when the app subscribed to it, else the label of a card. `state` is `null` before Home Assistant sends the state. `uptime` is the seconds since the boot at the write.
