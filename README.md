# tsx-linux-common

The software that every TSX panel family shares: the base services, the rescue screen, the boot splash, the kiosk, the setup page, the Home Assistant layer, the front buttons and the automatic update. Each panel family keeps its board files in its own repo.

## Documentation

| Page | Contents |
|---|---|
| [docs/index.md](docs/index.md) | The list of pages. |
| [docs/layout.md](docs/layout.md) | The directories, the packages, the services, the board interface and the tests. Read it to build a package or to port the software to a new board. |
| [docs/adaptive-brightness.md](docs/adaptive-brightness.md) | The learning brightness curve, its settings and its limits. |
| [docs/camera.md](docs/camera.md) | The camera modes for Home Assistant (off, snapshot, live), privacy, the defaults and the limits. |
| [docs/esphome.md](docs/esphome.md) | The two services of the Home Assistant device and the fixed entity keys. |

## Repository layout

| Directory | Package |
|---|---|
| `base/` | tsx-base |
| `kiosk/` | tsx-kiosk |
| `setup/` | tsx-setup |
| `ha/` | tsx-ha |
| `buttons/` | tsx-buttons |
| `autoupdate/` | tsx-autoupdate |
| `rescue/` | tsx-rescue-ui |
| `splash/` | tsx-splash |
| `tests/` | The host tests. Run `tests/run-all.sh`. |
| `ci/` | `lint.sh` and the CI checks. Run `ci/lint.sh`. |

## License

GPL-2.0-or-later. See [LICENSE](LICENSE).
