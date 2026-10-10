# tsx-linux-common

This repo holds the software that all TSX panel families share. Each family keeps its board files in its own repo.

- [Adaptive brightness](adaptive-brightness.md): how the automatic brightness learns, its settings and its limits.
- [Front keys](buttons.md): the board layer and the user file of the keys, what a key press does, the key LEDs and `tsx-kiosk-page`.
- [ESPHome device](esphome.md): the two services of the Home Assistant device, the fixed entity keys and the plugins of a board.
- [Kiosk hooks](kiosk-hooks.md): the `kiosk.d` folder, with which a board changes the renderer choice and the browser flags.
- [Layout](layout.md): directories, packages, the board interface, the plugin folders and the tests. Read it to build a package or to port the software to a new board.
- [Panel app](panel-app.md): the native Home Assistant card screen (ESPHome and LVGL), its JSON layout format, the reload and the log lines. Experimental.
- [LED bar](ledbar.md): the tools of the USB RGB LED bar, the settings, the recovery from bootloader mode, the effects, the 16 LEDs and the LED map.
- [Wake words](wake-words.md): the built-in wake words of the voice satellite, and how to add a custom wake word model.
