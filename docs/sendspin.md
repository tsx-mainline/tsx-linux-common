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

The panel has one volume. While the player runs, the volume of the panel is the player volume of Music Assistant:

- The setup page, `tsx-panelctl volume`, the Home Assistant number "Volume" of the panel, `tsx-mqtt` and the overlay of the panel app show and set the player volume.
- A change in Music Assistant or in Home Assistant (the media player of the panel) shows on all of them, in about a second.
- `sendspin-cli` scales the stream by (volume/100)^1.5: 100 % = 0 dB, 60 % = -6.7 dB, 50 % = -9 dB, 30 % = -15.7 dB, 10 % = -30 dB.
- The mute is the mute of the player. The setup page has a "Mute" box, and a tap on the volume icon of the overlay of the panel app mutes or unmutes. `tsx-panelctl get mute` and `send mute on|off` read and set it.
- The mixer of the board (`Master`) stays at a fixed level. Nothing on the panel shows it or changes it. The board sets the level with `TSX_VOLUME_FIXED_CMD` of `board.sh` when the service starts. A board without that command keeps `Master` where it is. The speaker limits of the board stay below the mixer.

How it works:

1. The service starts `sendspin-cli` with `--volume-file /run/sendspin-cli/volume`. The player writes its volume and mute to that file (mode 644) when it starts and at each change: `volume = 40` and `muted = false`.
2. `tsx-panelctl` and the panel app read the file. The file is also the sign that the player owns the volume.
3. A change on the panel goes to `tsx-panelctl` (root). It runs `sendspin-cli player-vol N` or `player-mute on|off` on the control socket of the player. The player applies the value and tells Music Assistant.
4. When the service stops, it removes the file. The mixer is then the volume of the panel again, at the fixed level. `SENDSPIN=off` does this.

`player-vol`, `player-mute` and `--volume-file` come from a patch of the package sendspin-cli (0.3.0-r1 and later). With an older `sendspin-cli`, the service writes a warning, and `Master` stays the volume of the panel.

### Announcements

Music Assistant plays an announcement on a Sendspin player through the player itself. The player of this package has no announcement feature of its own. So Music Assistant does these steps:

1. It stops the music of the player, if it plays.
2. It unmutes the player, if it is muted.
3. It sets the player volume to the announcement volume (the "Announcement volume" settings of the player in Music Assistant), when that volume is not the same as the present one.
4. It plays the announcement.
5. It sets the player volume back to the old value, mutes the player again if it was muted, and starts the music again.

The announcement volume is the player volume during the announcement. Nothing scales it again. During the announcement, the panel shows the announcement volume (and no mute). After the announcement, the panel shows the old volume again. Music Assistant sets the old volume at the end of the announcement. So a change on the panel during an announcement does not stay.

## Least privilege

The player has its own user. It can play sound (group `audio`), talk to avahi over D-Bus and write its state folder, its control socket in `/run/sendspin-cli` and its log. It cannot read `panel.conf` or the HA API key. See [security.md](security.md).
