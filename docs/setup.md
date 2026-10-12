# Setup page

`tsx-setupd` serves the setup page of the panel at `http://<panel-ip>:8080/setup`. The page sets the values of `panel.conf`, and it has live controls for the screen, the sound and the lights. This file tells who can open the page and how. The fields of each family are in the docs of the board repository.

## Who can open the page

| Client | Login |
|---|---|
| The panel itself (loopback, the kiosk browser) | None |
| A browser on the LAN | "Log in with Home Assistant" with an administrator account, or the pairing code of the screen |

The page is always on the LAN when the panel knows the URL of its Home Assistant. Without that URL, the LAN can open the page only while the pairing code works. The pairing code works while the panel is not configured, and for about 15 minutes after `tsx-config setup` or the *Setup* button of the overlay. At other times, the server listens on `127.0.0.1` only.

`TSX_SETUP_LAN=off` in `/etc/tsx/setup.conf` keeps the page off the LAN, also for the login. `TSX_SETUP_HA_LOGIN=off` turns off the login with Home Assistant and keeps the pairing code.

## Log in with Home Assistant

The panel uses the login of its own Home Assistant. An administrator of that Home Assistant opens the page of any panel with no code.

1. Open `http://<panel-ip>:8080/setup` in a browser.
2. Click *Log in with Home Assistant*.
3. Log in on the login page of Home Assistant.
4. Accept the access for the panel.

The browser comes back to the setup page with a session.

### The Home Assistant URL

The panel uses the first of these values:

1. `HA_URL` of `panel.conf`, for example `https://ha.example.org:8123`. Only the scheme, the host and the port count.
2. The origin of `KIOSK_URL` of `panel.conf`.
3. The origin of `KIOSK_URL` of `/etc/kiosk.conf` (the image default of a kiosk panel).

A kiosk panel that shows Home Assistant needs no `HA_URL`. A panel with the native panel app has no `KIOSK_URL`. Set `HA_URL` on it once: on the setup page with the pairing code, or over ssh with `tsx-config set HA_URL URL` and `tsx-config apply`. An install that writes `panel.conf` can set it too. After that, the panel needs no code again.

Only a person who can already change the panel sets `HA_URL` or `KIOSK_URL`. The panel never takes the URL from the network (for example from mDNS discovery). A false Home Assistant on the LAN could otherwise give a login to the page.

### The steps of the login

| Step | What happens |
|---|---|
| Start | `GET /setup/login` sends the browser to `<HA>/auth/authorize` with `client_id` = the origin of the page (`http://<panel-ip>:8080/`), `redirect_uri` = `<origin>/setup/auth/callback` and a random `state`. The `state` also goes into the cookie `tsxlogin` (HttpOnly, SameSite=Lax, 10 minutes). |
| Return | Home Assistant sends the browser back with a code. `tsx-setupd` checks that the `state` matches the cookie, the address of the browser and a login that it started. A `state` works once. |
| Code | `tsx-setupd` sends the code to `<HA>/auth/token` and gets an access token and a refresh token. |
| Admin check | `tsx-setupd` opens the websocket API `<HA>/api/websocket` with the access token and sends `auth/current_user`. Only a user with `is_admin` gets a session. |
| Revoke | `tsx-setupd` sends the refresh token to `<HA>/auth/revoke`. Home Assistant removes the refresh token and its access tokens. The panel keeps no token of Home Assistant. |
| Session | The browser gets the cookie `tsxsetup` (HttpOnly, SameSite=Strict, Path=/setup) and the cookie `tsxcsrf` (see "CSRF"). |

Home Assistant accepts a `client_id` with a local IP address, and a `redirect_uri` on the same host. The panel must reach Home Assistant at the Home Assistant URL. With `https`, the certificate must be valid for the CA list of the panel.

A user who is not an administrator gets "Only an administrator can open the setup page" and no session. A canceled login gives no session either.

### Sessions

| Rule | Value |
|---|---|
| Duration | `TSX_SETUP_SESSION` seconds after the login (default 28800, 8 hours) |
| Idle limit | `TSX_SETUP_IDLE` seconds after the last request (default 3600) |
| Number | At most 32 sessions. A new session ends the oldest one. |
| Storage | In the memory of `tsx-setupd`. A restart of `tsx-setupd` ends all sessions. |

The page shows the user of the session and a *Log out* button. *Sessions of this panel* lists all sessions with the user, the address and the age. Each entry has a *Log out* button. *Log out all browsers* ends all sessions of the panel. A logout or a revoke takes effect at once.

A session of the pairing code works only while the pairing code works.

### CSRF

Every POST request must pass these checks:

- The body is JSON (`Content-Type: application/json`). A form post gets 415.
- An `Origin` header, when the browser sends one, is the origin of the page. `Sec-Fetch-Site`, when the browser sends it, is `same-origin`.
- The header `X-TSX-CSRF` has the CSRF token of the session. The kiosk browser on the panel has its own token. The state API (`csrf`) and the cookie `tsxcsrf` give the token to the page.

`POST /setup/api/pair` comes before a session. It has the first two checks and its own rate limit.

### Rate limits

| Request | Limit |
|---|---|
| `GET /setup/login` | 20 for each address and 60 for all addresses in 10 minutes |
| The return from Home Assistant | 30 for each address in 10 minutes |
| The pairing code | 10 wrong codes for each address in the window |

### What a remote save does

A save from a remote session writes the changed fields and runs `tsx-config apply`. It restarts the kiosk only when it changes `KIOSK_URL`, `HA_LOGIN_METHOD` or `HA_TOKEN`. A save from the screen of the panel or from a pairing session closes the setup window and restarts the kiosk, as before.

## Panel section

The *Panel* section has live controls. A control shows only when the panel has the part.

| Control | Panel | Backend |
|---|---|---|
| Screen on and off | All | `tsx-panelctl send blank` |
| Brightness, 1 to 100 % | All | `tsx-panelctl send brightness-pct` |
| Volume, 0 to 100 % | A sound card | `tsx-panelctl send volume`. While the Sendspin player runs, it is the player volume, and a "Mute" box mutes the player (`tsx-panelctl send mute`). See [Sendspin](sendspin.md) "Audio and volume" |
| Dim the screen after, dim level | Panel app | `tsx-config set DIM_TIMEOUT` or `DIM_LEVEL`, then `apply` |
| Turn the screen off after | All | `tsx-config set BLANK_TIMEOUT`, then `apply` |
| Update mode: auto or manual | A panel with `tsx-autoupdate` | `tsx-config set UPDATE_MODE`, then `apply` |
| Automatic restart: on or off | A panel with `tsx-autoupdate` | `tsx-config set UPDATE_AUTO_RESTART`, then `apply` |
| LED bar: on, color, brightness | A LED bar | `tsx-panelctl send ledbar` |
| Key LEDs: on, level | Keys with LEDs | `tsx-panelctl send keypad led` |
| Panel lights: on, color, brightness | Panel app with `panel_lights` | `tsx-panelctl send lights` |

These are the backends of the overlay and of the Home Assistant entities. So the page, the overlay and Home Assistant show the same values. On a panel with the panel app, `tsx-panelctl` hands the screen, the brightness and the lights to the app (see "Control from the panel" in [panel-app.md](panel-app.md)).

The times and the two update settings go to `panel.conf` and stay after a reboot. The brightness, the volume and the lights act at once, as the overlay does. The page reads the values every 5 s.

### Update settings

The *Update mode* select and the *Automatic restart* box set how the panel installs updates. The page shows them only when `tsx-panelctl state` has the lines `update-mode` and `auto-restart`. The Home Assistant entities with the same names, "Update mode" (a select) and "Automatic restart" (a switch), show and change the same two settings.

- Update mode `auto`: the panel installs updates in the update window while the screen is idle. If an update needs a restart, the panel restarts after the install when Automatic restart is on.
- Update mode `manual`: the panel checks for updates and shows them in Home Assistant, but it never installs them by itself.
- Automatic restart: when it is off, the panel does not restart by itself. Home Assistant shows "Restart required" until you restart the panel.

The *Install* button of the update entity in Home Assistant works in both modes. The page saves the settings as `UPDATE_MODE` (`auto` or `manual`) and `UPDATE_AUTO_RESTART` (`on` or `off`) in `panel.conf`. `tsx-config apply` writes them as `MODE` and `AUTO_RESTART` to `/run/tsx/autoupdate.conf`. `tsx-autoupdate` reads that file after `/etc/tsx/autoupdate.conf`, so the page value wins. See [autoupdate.md](autoupdate.md).

### How the page reads and sends

`tsx-setupd` gets the values with the helper command `panel-state` (`tsx-panelctl state` as root). It sends a change with the helper command `panel`. The helper passes only the exact forms of the table above, and `tsx-panelctl` checks the ranges again.

## API

| Path | Method | Function |
|---|---|---|
| `/setup` | GET | The page |
| `/setup/login` | GET | Start of the login with Home Assistant |
| `/setup/auth/callback` | GET | The return from Home Assistant |
| `/setup/api/state` | GET | The values of `panel.conf`, the revision, the CSRF token and the session. Without a session: what the client can do (`login`, `pairing`, `ha_host`). |
| `/setup/api/status` | GET | The pairing code (loopback only) and the revision |
| `/setup/api/pair` | POST | `{"code": "123456"}` |
| `/setup/api/submit` | POST | `{"revision": ..., "fields": {...}}` |
| `/setup/api/panel` | GET, POST | The live controls. POST `{"control": NAME, "value": ...}` |
| `/setup/api/sessions` | GET | The sessions |
| `/setup/api/sessions/revoke` | POST | `{"id": ID}` or `{"all": true}` |
| `/setup/api/logout` | POST | End the session of this browser |

## Settings

| Key of `/etc/tsx/setup.conf` | Default | Meaning |
|---|---|---|
| `TSX_SETUP_PORT` | 8080 | The port |
| `TSX_SETUP_LAN` | `on` | `off`: no LAN access |
| `TSX_SETUP_HA_LOGIN` | `on` | `off`: no login with Home Assistant |
| `TSX_SETUP_SESSION` | 28800 | Seconds that a session lasts |
| `TSX_SETUP_IDLE` | 3600 | Seconds without a request before a session ends |
| `TSX_SETUP_WINDOW` | 900 | Seconds that the pairing code works after `tsx-config setup` |
| `TSX_SETUP_KIOSK` | `auto` | Does the panel run the browser kiosk |

## Files

| File | Function |
|---|---|
| `setup/usr/local/sbin/tsx-setupd` | The server. It runs as the user `tsx-setup`, with no privilege. |
| `setup/usr/local/lib/tsx/setup_ha_login.py` | The Home Assistant side of the login: the code exchange, the websocket API and the revoke. Standard library only. |
| `setup/usr/local/sbin/tsx-setup-helper` | The root helper with a fixed command set. |

## Tests

| Test | What it checks |
|---|---|
| `tests/test-setup-login.sh` | The login against a fake Home Assistant (`tests/fake-ha.py`): the redirect, the return, the admin check, the refusal of a user who is not an administrator, a replayed or foreign return, the revoke of the refresh token, CSRF, the session list, a revoke, a logout, the expiry, the rate limit, the Panel section and the allowlist of the helper |
| `tests/test-setup.sh` | The pairing code, the save, the revision and the helper |
| `tests/test-setup-page.sh` | The script of the page in node: the fields, the gate, the session bar, the Panel section and the CSRF header |
