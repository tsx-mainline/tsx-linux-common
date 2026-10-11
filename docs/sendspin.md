# Sendspin

The package tsx-sendspin plays music from Music Assistant on the speaker of the panel. It runs `sendspin-cli`, the C++ client of the Sendspin protocol (the package sendspin-cli of tsx-aports). Any panel with a sound card can install it. It needs no kiosk, no browser and no Home Assistant layer. On the kiosk panels, tsx-ha depends on it, so those panels get it as before.

## Files

| File | Contents |
|---|---|
| `/etc/init.d/tsx-sendspin` | The service. It runs `sendspin-cli` as the user `tsx-sendspin` in the group `audio`. |
| `/etc/tsx/sendspin.conf` | The settings: the name, the client id, the ALSA output, the formats, the buffer, the delay and the server. Each key has a comment in the file. |
| `/etc/logrotate.d/tsx-sendspin` | The rotation of `/var/log/tsx-sendspin.log`. |
| `/usr/local/lib/tsx/config.d/sendspin.sh` | The plugin of `tsx-config` for the key `SENDSPIN`. |

The state of the player (its client id and its last volume) is in `/var/lib/sendspin`. The service gives the folder to the user `tsx-sendspin` at each start. Up to 0.3.4 the player ran as the user `kiosk`. The service keeps the state of that user.

## The player name

The name in Music Assistant is `SENDSPIN_NAME` of `sendspin.conf`. Without it, the name is `PANEL_NAME` of `panel.conf` (`tsx-config apply` writes it to `/run/tsx/sendspin.conf`), else the host name. The product name is the model of the board (`tsx_board_ha_model`).

## On and off

The package does not start the player. Use the key `SENDSPIN` of `panel.conf`:

1. Run `tsx-config set SENDSPIN on`.
2. Run `tsx-config apply`.

`apply` puts `dbus`, `avahi-daemon` and `tsx-sendspin` into the default runlevel and starts them. The player tells Music Assistant about itself over mDNS (`_sendspin._tcp`). Music Assistant connects to it, and Home Assistant shows a media player with the name of the player.

`SENDSPIN=off` stops `tsx-sendspin` and takes it out of the runlevel. `dbus` and `avahi-daemon` stay, because other services can use them. Without the key, `apply` does not change the runlevel: an image or the audio tool of a board can enable the player (for example `tsx-audio enable sendspin` of a board). A panel with no sound card (`TSX_SOUND_CARD` of `board.sh` is empty) accepts `SENDSPIN=on` with a warning and keeps the player off.

## Audio and volume

The player plays to `SENDSPIN_OUTPUT`, by default `alsa:media`: the `media` PCM of `/etc/asound.conf` of the board. The board makes it a softvol `Media` on top of the softvol `Master`, on a dmix. So other users can play at the same time (sounds of the panel, a voice feature), and a voice feature can turn the music down with `Media`.

Two volumes act on the music:

- The player volume of Music Assistant or Home Assistant. `sendspin-cli` scales the stream by (volume/100)^1.5.
- The volume of the panel: `Master`. The setup page, `tsx-panelctl volume`, the Home Assistant number "Volume" of the panel and the overlay of the panel app set it.

## Least privilege

The player has its own user. It can play sound (group `audio`), talk to avahi over D-Bus and write its state folder, its control socket in `/run/sendspin-cli` and its log. It cannot read `panel.conf` or the HA API key.
