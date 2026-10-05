# Kiosk hooks

A board package can change how `kiosk-session` chooses the renderer and the browser flags. It ships a hook for this. A hook is a shell file in `/usr/local/lib/tsx/kiosk.d`.

Use a hook when a GPU or a browser build needs its own rules. For example, a GPU with OpenGL ES 2.0 only needs a patched Chromium. The shared code does not know that rule. The hook of the board does.

## When a hook runs

`kiosk-session` picks the display, the render node and the GPU mode from the board values and `KIOSK_GPU`. Then it sources each hook. After the hooks, it exports `WLR_RENDERER` and builds the browser command line.

`kiosk-session` runs twice: as the session and again as `kiosk-session --browser`. The hooks run in both roles, as the kiosk user. A hook must give the same result each time.

## Rules for the files

- The folder is `/usr/local/lib/tsx/kiosk.d`.
- Only files with a name that ends in `.sh` run. They run in name order.
- Root must own the folder and each file. Group and others must not write them.
- A symbolic link does not run.
- A file that breaks a rule gets one log line and is skipped. The other files still run.
- A file with a syntax error gets one log line and is skipped.
- A folder that breaks a rule gets one log line. No file in it runs.

Use a number at the start of the name when the order matters, for example `10-gpu.sh`. Two packages can ship two hooks without a file conflict.

The hook runs in the shell of `kiosk-session` with `set -u`. A hook that uses an unset name stops the session. Use `${NAME:-}` for a name that can be empty.

## What a hook reads

| Name | Meaning |
|---|---|
| `KIOSK_GPU` | The GPU mode from `kiosk.conf`, `panel-board.conf` or `panel.conf`. |
| `disp`, `dispdrv` | The display device (for example `/dev/dri/card2`) and its driver name. Both are empty when no display exists. |
| `render`, `renderdrv` | The render node (for example `/dev/dri/renderD128`) and its driver name. Both are empty when no render node exists. |
| The board values | The names of `board.sh`, for example `TSX_RENDER_DRM`. |
| `log TEXT` | Writes one line to the kiosk log. It prints in the session role only. |

## What a hook changes

A hook changes only these four names. The script sets the first three from its own choice before the hooks run. It reads all four after the hooks.

| Name | Start value | Meaning |
|---|---|---|
| `KIOSK_GL_COMPOSITOR` | 1 when the script picked GLES for the compositor, else 0 | 1 = GLES in the compositor. 0 = pixman. Another value counts as 0. |
| `KIOSK_GL_BROWSER` | 1 when the script picked the GPU for the browser, else 0 | 1 = GPU compositing in the browser. 0 = software rendering. Another value counts as 0. |
| `KIOSK_BROWSER_GL_FLAGS` | `TSX_BROWSER_GL_FLAGS` of the board | The Chromium flags for a browser that uses the GPU. A hook replaces the whole list. |
| `KIOSK_DISABLE_FEATURES` | The comma list of `kiosk.conf` | The Chromium features to turn off. A hook adds to the list and keeps the old entries. |

`kiosk-session` always adds `--ignore-gpu-blocklist` before the flags of a browser that uses the GPU. A hook does not add it.

## GPU modes

`KIOSK_GPU` has four modes in the shared code: `auto`, `on`, `compositor` and `off`. A value that the shared code and the hooks do not know counts as `auto`. A hook can add a mode and read `KIOSK_GPU` to find it. Before the hooks run, the script treats the new mode as `auto`. The hook then sets the names that its mode needs.

## Example

This hook turns the GPU browser off for a GPU that supports OpenGL ES 2.0 only:

```sh
# 10-gles2.sh
if [ "$KIOSK_GL_BROWSER" = 1 ] && [ "$renderdrv" = examplegpu ]; then
	KIOSK_GL_BROWSER=0
	log "GPU is $renderdrv (GLES 2.0): the browser renders in software"
fi
```

The xx60 board package ships a hook of this kind. It also adds the mode `browser`, which needs the patched Chromium of the xx60. See the xx60 documentation.

## Tests

Two names help a host test:

- `TSX_KIOSK_HOOK_DIR` replaces the folder.
- `TSX_KIOSK_HOOK_UID` replaces the user id that counts as root (default 0). A test uses the id of the user who runs it.

`tests/test-board-fake.sh` runs `kiosk-session` with fake hook files. It checks the order, the four names, the skip rules and the log lines.
