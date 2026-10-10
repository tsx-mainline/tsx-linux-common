# tsx-linux-common

The software that every TSX panel family shares: the base services, the rescue screen, the boot splash, the kiosk, the setup page, the Home Assistant layer, the front buttons, the USB LED bar tools and the automatic update. Each panel family keeps its board files in its own repo.

## Documentation

| Page | Contents |
|---|---|
| [docs/index.md](docs/index.md) | The list of pages. |
| [docs/layout.md](docs/layout.md) | The directories, the packages, the services, the board interface and the tests. Read it to build a package or to port the software to a new board. |
| [docs/adaptive-brightness.md](docs/adaptive-brightness.md) | The learning brightness curve, its settings and its limits. |
| [docs/buttons.md](docs/buttons.md) | The board layer and the user file of the front keys, what a key press does and the key LEDs. |
| [docs/esphome.md](docs/esphome.md) | The two services of the Home Assistant device, the fixed entity keys and the plugins of a board. |
| [docs/kiosk-hooks.md](docs/kiosk-hooks.md) | The `kiosk.d` folder, with which a board changes the renderer choice and the browser flags. |
| [docs/ledbar.md](docs/ledbar.md) | The USB RGB LED bar: the tools, the settings, the bootloader recovery, the effects, the 16 LEDs and the LED map. |
| [docs/panel-app.md](docs/panel-app.md) | The native Home Assistant card screen (ESPHome and LVGL) and its JSON layout format. Experimental. |
| [docs/wake-words.md](docs/wake-words.md) | The built-in wake words of the voice satellite, and how to add a custom wake word model. |

## Repository layout

| Directory | Package |
|---|---|
| `base/` | tsx-base |
| `kiosk/` | tsx-kiosk |
| `setup/` | tsx-setup |
| `ha/` | tsx-ha |
| `buttons/` | tsx-buttons |
| `autoupdate/` | tsx-autoupdate |
| `ledbar/` | tsx-ledbar |
| `rescue/` | tsx-rescue-ui |
| `splash/` | tsx-splash |
| `panel-app/` | none yet (the panel app, a test) |
| `tests/` | The host tests. Run `tests/run-all.sh`. |
| `ci/` | `lint.sh`, `check-generic.sh` (no family name outside `docs/`) and the other CI checks. Run `ci/lint.sh` and `ci/check-generic.sh`. |

## License

GPL-2.0-or-later. See [LICENSE](LICENSE).
