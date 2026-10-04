# tsx-linux-common

This repo holds the software that all TSX panel families share. Each family keeps its board files in its own repo.

- [Adaptive brightness](adaptive-brightness.md): how the automatic brightness learns, its settings and its limits.
- [Camera](camera.md): the camera modes for Home Assistant, privacy, the defaults and the limits.
- [ESPHome device](esphome.md): the two services of the Home Assistant device and the fixed entity keys.
- [Layout](layout.md): directories, packages, the board interface and the tests. Read it to build a package or to port the software to a new board.
- [Wake words](wake-words.md): the built-in wake words of the voice satellite, and how to add a custom wake word model.
