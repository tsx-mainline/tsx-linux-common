#!/bin/bash
# Host test: the shared panel software on boards that are not real. Board A
# is the test board of tests/boards/fake. Board B is made up in this test. It
# differs from A in every value (driver names, sound card, Bluetooth, MAC).
# The test runs the real scripts against each board. It checks that the
# values of the board show, that no value of the other board shows, and that
# no name of real hardware shows. It needs no panel and no compiler.
#   - the rescue screen: model, firmware, unit, MAC source, extra line
#   - the kiosk renderer selection, with a fake sysfs
#   - the kiosk.d hooks of kiosk-session, with fake hook files
#   - tsx-config apply: repository category, Bluetooth defaults, BT_MAC
#   - tsx-mqtt: the Home Assistant model and the volume entity
#   - tsx-autoupdate: the package names
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/paths.sh"
. "$(dirname "$0")/lib/board.sh"
# Each call below names its board. So the test keeps no board in the environment.
BOARDA=$TSX_BOARD_CONF; unset TSX_BOARD_CONF TSX_BOARD_BIN
BOARDB=$(mktemp -d)/board.sh; T=$(dirname "$BOARDB"); trap 'rm -rf "$T"' EXIT
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-board-fake: no busybox on this host"; exit 0; }
N=0 F=0
ok()  { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
# Names of real hardware. A board that is not real must not show them.
REAL='uboot|u-boot|xx60|TSS-10|TSW-1060|meson|lima|ttyAML'

: > "$T/nolib.sh"
cat > "$BOARDB" <<'EOB'
# Board B: a made-up board
TSX_FAMILY=second
TSX_APK_CATEGORY=second
TSX_HA_MODEL=second
TSX_SOUND_CARD=SecondCard
TSX_DISPLAY_DRM="seconddrm*"
TSX_RENDER_DRM="secondgpu"
TSX_DISPLAY_ENV="SECOND_NOMOD=1 SECOND_FORMAT=argb8888"
TSX_BT_CHIP=none
TSX_BT_PROXY_DEFAULT=off
TSX_BT_MAC_SETTABLE=yes
TSX_MAC_SOURCE=secondstore
TSX_MAC_DEV=/dev/null
tsx_board_load() { :; }
tsx_board_probe() { return 0; }
tsx_board_model() { echo SECOND-200; }
tsx_board_stock_fw() { echo v2.4.0; }
tsx_board_unit_id() { echo second-0002; }
tsx_board_mac() { echo 02:5e:c0:00:00:09; }
tsx_board_mac_early() { tsx_board_mac; }
tsx_board_mac_source() { echo "$TSX_MAC_SOURCE"; }
tsx_board_hostname_hint() { :; }
tsx_board_ha_model() { echo SECOND-200; }
tsx_board_rescue_extra() { :; }
EOB
busybox sh -n "$BOARDA" && ok "board A is valid shell"
busybox sh -n "$BOARDB" && ok "board B is valid shell"

echo "== rescue screen =="
RS=$HERE/rescue/usr/sbin/tsx-rescue-status
mkdir -p "$T/run" "$T/sbin"
printf '#!/bin/sh\necho "2: eth0    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0"\n' > "$T/sbin/ip"
printf '#!/bin/sh\necho 6.18.0\n' > "$T/sbin/uname"
chmod 755 "$T/sbin/ip" "$T/sbin/uname"
echo "02:5a:11:22:33:44" > "$T/mac"; echo "quiet" > "$T/cmdline"
echo "02:fa:ce:00:00:07" > "$T/fakemac"
sed -e "s|/proc/cmdline|$T/cmdline|g; s|ip -4 -o addr show eth0|$T/sbin/ip|g; s|uname -r|$T/sbin/uname|; s|/sys/class/net/eth0/address|$T/mac|" \
    -e 's|> /dev/kmsg|> /dev/null|; s|> "\$TTY"|>> "$TTY"|' "$RS" > "$T/rs.sh"
render() { # BOARDFILE
	: > "$T/frame.raw"
	TSX_BOARD_CONF=$1 TSX_MAC_DEV=$T/fakemac TSX_RUN=$T/run TSX_STATUS_TTY=$T/frame.raw TSX_LIB=$T/nolib.sh TSX_VERFILE=$T/none TSX_STATUS_IN=$T/keys \
		TSX_STATUS_WAIT=1 sh "$T/rs.sh" once
	sed 's/\x1b\[[0-9?;]*[A-Za-z]//g' "$T/frame.raw" > "$T/frame"; }
render "$BOARDA"
grep -qx 'model        : FAKE-100   stock fw v7.3.1   unit fake-0001' "$T/frame" && ok "model, stock firmware and unit come from the board file" || bad "model line: $(grep '^model' "$T/frame")"
grep -qx 'board line   : fake' "$T/frame" && ok "the extra rescue line of the board shows" || bad "no extra rescue line"
echo fakefile > "$T/run/tsx-eth0-mac-src"; render "$BOARDA"
grep -qx 'network      : eth0 192.0.2.10 (dhcp, MAC 02:5a:11:22:33:44, fakefile)' "$T/frame" && ok "the MAC source name of the file is shown as written by rcS" || bad "network: $(grep '^network' "$T/frame")"
rm -f "$T/run/tsx-eth0-mac-src"; render "$BOARDA"
grep -qx 'network      : eth0 192.0.2.10 (dhcp, MAC 02:fa:ce:00:00:07, fakefile)' "$T/frame" && ok "before rcS has set the MAC: the MAC from the file of the board and the source name" || bad "network: $(grep '^network' "$T/frame")"
grep -qiE "$REAL|SECOND|secondstore" "$T/frame" && bad "a name of real hardware or of board B shows on the screen" || ok "no name of real hardware or of board B on the screen"
TSX_FAKE_NO_MAC=1 render "$BOARDA"
grep -qx 'network      : eth0 192.0.2.10 (dhcp)' "$T/frame" && ok "a board with no MAC: the screen shows none" || bad "the screen shows a MAC when the board gives none: $(grep '^network' "$T/frame")"
render "$BOARDB"
grep -qx 'model        : SECOND-200   stock fw v2.4.0   unit second-0002' "$T/frame" && ok "board B: model, stock firmware and unit" || bad "board B model line: $(grep '^model' "$T/frame")"
grep -q 'board line' "$T/frame" && bad "board B shows the extra line of board A" || ok "board B: no extra rescue line"
grep -qx 'network      : eth0 192.0.2.10 (dhcp, MAC 02:5e:c0:00:00:09, secondstore)' "$T/frame" && ok "board B: its own MAC and source name" || bad "board B network: $(grep '^network' "$T/frame")"
grep -qiE "$REAL|FAKE|fakefile" "$T/frame" && bad "a name of real hardware or of board A shows on the screen" || ok "board B: no name of real hardware or of board A on the screen"

echo "== kiosk renderer selection (fake sysfs) =="
KS=$(P usr/local/bin/kiosk-session)
sed -n '/^# --- renderer selection/,/^log "display=/p' "$KS" > "$T/sel.sh"
[ "$(wc -l < "$T/sel.sh")" -gt 20 ] && ok "the renderer selection is in kiosk-session" || bad "cannot find the renderer selection"
mkdir -p "$T/drivers/fakedrm" "$T/drivers/seconddrm" "$T/drivers/secondgpu" "$T/drivers/simple-framebuffer"
# mkdrm DIR [CARD:DRIVER[:connector]...] RENDER:DRIVER
mkdrm() { d=$1; shift; rm -rf "$d"; mkdir -p "$d"
	for a in "$@"; do
		case "$a" in
		render:*) drv=${a#render:}; mkdir -p "$d/renderD128/device"; ln -s "$T/drivers/$drv" "$d/renderD128/device/driver";;
		*) c=${a%%:*}; drv=${a#*:}; mkdir -p "$d/$c/device"; ln -s "$T/drivers/$drv" "$d/$c/device/driver"; mkdir -p "$d/$c-CONN-1"
			# a display driver has a connector inside its card. A GPU with no display (secondgpu) has none.
			case "$drv" in secondgpu) ;; *) mkdir -p "$d/$c/$c-CONN-1";; esac;;
		esac
	done; }
# HOOKDIR names a kiosk.d folder, HOOKUID the owner that counts as root (default: the user of the test).
sel() { # DRMDIR BOARDFILE [KIOSK_GPU]
	env -i PATH="$PATH" TSX_BOARD_CONF="$2" TSX_DRM_SYS="$1" KIOSK_GPU="${3:-auto}" KIOSK_RENDER_ENV="${KIOSK_RENDER_ENV:-auto}" \
		TSX_KIOSK_HOOK_DIR="${HOOKDIR:-$T/no-kiosk.d}" TSX_KIOSK_HOOK_UID="${HOOKUID:-$(id -u)}" KIOSK_DISABLE_FEATURES="${KIOSK_DISABLE_FEATURES:-}" sh -c '
		set -u   # as in kiosk-session
		KIOSK_OSK=off KIOSK_URL=u ROLE=session
		log() { echo "log: $*"; }
		. "$TSX_BOARD_CONF"
		. '"$T"'/sel.sh
		echo "WLR_RENDERER=$WLR_RENDERER WLR_DRM_DEVICES=${WLR_DRM_DEVICES:-} SECOND=${SECOND_NOMOD:-}/${SECOND_FORMAT:-} RENV=${FAKE_GPU_DEBUG:-}"
		echo "comp_gl=$comp_gl browser_gl=$browser_gl flags=$KIOSK_BROWSER_GL_FLAGS features=$KIOSK_DISABLE_FEATURES"' 2>&1; }
# Board B has a display driver and a GPU that offers GLES 2.0 only (secondgpu: card0, no display).
mkdrm "$T/drmb" card0:secondgpu card2:seconddrm render:secondgpu
# The GLES 2.0 rule is not in kiosk-session. Board B ships it as a kiosk.d hook.
out=$(sel "$T/drmb" "$BOARDB")
echo "$out" | grep -q "^log: display=/dev/dri/card2 (seconddrm) render=/dev/dri/renderD128 renderer=gles2 browser_gpu=1" && ok "board B with no hook: display card, render node of the GPU, GLES in the compositor and in the browser" || bad "board B, no hook: $out"
echo "$out" | grep -q "GLES 2.0" && bad "board B with no hook: a GLES 2.0 note" || ok "board B with no hook: kiosk-session has no GLES 2.0 rule of its own"
mkdir -p "$T/hooks-b"; chmod 755 "$T/hooks-b"
cat > "$T/hooks-b/10-secondgpu.sh" <<'EOH'
# Hook of board B: secondgpu offers OpenGL ES 2.0 only. The browser needs more.
if [ "$KIOSK_GL_BROWSER" = 1 ] && [ "$renderdrv" = secondgpu ]; then
	KIOSK_GL_BROWSER=0
	log "GPU is $renderdrv (GLES 2.0): the browser renders in software"
fi
EOH
chmod 644 "$T/hooks-b/10-secondgpu.sh"
out=$(HOOKDIR=$T/hooks-b sel "$T/drmb" "$BOARDB")
echo "$out" | grep -q "^log: display=/dev/dri/card2 (seconddrm) render=/dev/dri/renderD128 renderer=gles2 browser_gpu=0" && ok "board B with its hook: display card, render node of the GPU, GLES in the compositor, software browser" || bad "board B: $out"
echo "$out" | grep -q "SECOND=1/argb8888" && ok "board B: the display variables are exported" || bad "board B variables: $out"
echo "$out" | grep -q "log: GPU is secondgpu (GLES 2.0)" && ok "board B: the note of the hook names the driver" || bad "board B note: $out"
mkdrm "$T/drma" card0:fakedrm render:fakedrm
out=$(sel "$T/drma" "$BOARDA")
echo "$out" | grep -q "^log: display=/dev/dri/card0 (fakedrm) render=/dev/dri/renderD128 renderer=gles2 browser_gpu=1" && ok "board A: fakedrm display and render node, GPU browser" || bad "board A: $out"
echo "$out" | grep -q "SECOND=/" && ok "board A: no display variables" || bad "board A variables: $out"
echo "$out" | grep -q "GLES 2.0" && bad "board A: a GLES 2.0 note for a GPU that is not on the list" || ok "board A: no GLES 2.0 note"
mkdrm "$T/drmas" card0:simple-framebuffer
out=$(sel "$T/drmas" "$BOARDA")
echo "$out" | grep -q "renderer=pixman" && ok "board A: only a simple framebuffer: pixman" || bad "board A, simple framebuffer: $out"
out=$(sel "$T/drmb" "$BOARDA")
echo "$out" | grep -q "^log: display=/dev/dri/card2 (seconddrm) render=none" && ok "board A on the hardware of board B: nothing of board B is assumed, the card with no connector is no display" || bad "board A on the hardware of board B: $out"
echo "$out" | grep -q "SECOND=/" && ok "board A on the hardware of board B: the display variables of B stay out" || bad "board A on the hardware of board B, variables: $out"
out=$(sel "$T/drma" "$BOARDB")
echo "$out" | grep -q "^log: display=/dev/dri/card0 (fakedrm) render=none" && ok "board B on the hardware of board A: no render node, a display driver of another board is used" || bad "board B on the hardware of board A: $out"
echo "$out" | grep -q "SECOND=/" && ok "board B on the hardware of board A: its display variables stay out for another driver" || bad "board B on the hardware of board A, variables: $out"
# a board with no TSX_RENDER_DRM takes any render node. TSX_RENDER_ENV names the GPU variables.
sed -e 's/^TSX_RENDER_DRM=.*/TSX_RENDER_DRM=/' -e '/^TSX_RENDER_DRM=/a TSX_RENDER_ENV="FAKE_GPU_DEBUG=sysmem"\nTSX_BROWSER_GL_FLAGS="--use-angle=gles"' "$BOARDA" > "$T/board-anyrender.sh"
out=$(sel "$T/drma" "$T/board-anyrender.sh")
echo "$out" | grep -q "render=/dev/dri/renderD128" && ok "an empty TSX_RENDER_DRM takes the first render node" || bad "any render node: $out"
echo "$out" | grep -q "RENV=sysmem" && ok "TSX_RENDER_ENV is exported with a render node" || bad "TSX_RENDER_ENV: $out"
out=$(KIOSK_RENDER_ENV=0 sel "$T/drma" "$T/board-anyrender.sh")
echo "$out" | grep -q "RENV=$" && ok "KIOSK_RENDER_ENV=0 keeps the GPU variables out" || bad "KIOSK_RENDER_ENV=0: $out"
mkdrm "$T/drman" card0:fakedrm
out=$(sel "$T/drman" "$T/board-anyrender.sh")
echo "$out" | grep -q "RENV=$" && ok "no render node: the GPU variables stay out" || bad "no render node: $out"

echo "== kiosk hooks (kiosk.d) =="
# hk DIR NAME CONTENT: a hook file that is safe (mode 644)
hk() { printf '%s\n' "$3" > "$1/$2"; chmod 644 "$1/$2"; }
mkhooks() { rm -rf "$1"; mkdir -p "$1"; chmod 755 "$1"; }
mkdrm "$T/drmh" card0:fakedrm render:fakedrm
# a hook reads the renderer facts and the starting values of the four names
H=$T/h1; mkhooks "$H"
hk "$H" 10-seen.sh 'log "hook sees gpu=$KIOSK_GPU disp=$disp dispdrv=$dispdrv render=$render renderdrv=$renderdrv card=$TSX_SOUND_CARD comp=$KIOSK_GL_COMPOSITOR browser=$KIOSK_GL_BROWSER flags=$KIOSK_BROWSER_GL_FLAGS"'
out=$(HOOKDIR=$H sel "$T/drmh" "$T/board-anyrender.sh")
echo "$out" | grep -q "^log: hook sees gpu=auto disp=/dev/dri/card0 dispdrv=fakedrm render=/dev/dri/renderD128 renderdrv=fakedrm card=FakeCard comp=1 browser=1 flags=--use-angle=gles$" && ok "a hook sees KIOSK_GPU, the display, the render node and its driver, the board values and the choice of the script" || bad "hook sees: $out"
echo "$out" | grep -q "^comp_gl=1 browser_gl=1 flags=--use-angle=gles features=$" && ok "a hook that changes nothing leaves the choice as it was" || bad "hook that changes nothing: $out"
# a hook changes the four names. The script reads them after the hook.
H=$T/h2; mkhooks "$H"
hk "$H" 20-change.sh 'KIOSK_GL_COMPOSITOR=0; KIOSK_GL_BROWSER=1; KIOSK_BROWSER_GL_FLAGS="--fake-gl-flag"; KIOSK_DISABLE_FEATURES="FakeFeature${KIOSK_DISABLE_FEATURES:+,$KIOSK_DISABLE_FEATURES}"'
out=$(KIOSK_DISABLE_FEATURES=Existing HOOKDIR=$H sel "$T/drmh" "$BOARDA")
echo "$out" | grep -q "WLR_RENDERER=pixman" && ok "a hook turns the GLES compositor off: pixman" || bad "hook compositor: $out"
echo "$out" | grep -q "^comp_gl=0 browser_gl=1 flags=--fake-gl-flag features=FakeFeature,Existing$" && ok "a hook changes the browser mode, the GPU flags and the disabled features" || bad "hook, four names: $out"
echo "$out" | grep -q "browser_gpu=1" && ok "the log line shows the browser mode after the hook" || bad "hook, log line: $out"
H=$T/h2b; mkhooks "$H"
hk "$H" 10-on.sh 'KIOSK_GL_COMPOSITOR=yes; KIOSK_GL_BROWSER=2'
out=$(HOOKDIR=$H sel "$T/drmh" "$BOARDA")
echo "$out" | grep -q "^comp_gl=0 browser_gl=0 " && echo "$out" | grep -q "WLR_RENDERER=pixman" && ok "a value other than 1 counts as 0" || bad "hook, bad values: $out"
H=$T/h2c; mkhooks "$H"
hk "$H" 10-unset.sh 'unset KIOSK_GL_COMPOSITOR KIOSK_GL_BROWSER'
out=$(HOOKDIR=$H sel "$T/drmh" "$BOARDA")
echo "$out" | grep -q "^comp_gl=0 browser_gl=0 " && ok "a hook that unsets the names gets 0, and the script goes on" || bad "hook, unset names: $out"
# the browser section uses the browser mode and the flags of the hook
sed -n '/^# --- browser ---/,/^mem=\$(awk/p' "$KS" | sed '$d' > "$T/browser.sh"
[ "$(wc -l < "$T/browser.sh")" -gt 30 ] && ok "the browser section is in kiosk-session" || bad "cannot find the browser section"
bflags() { # BROWSER_GL FLAGS FEATURES
	env -i PATH="$PATH" sh -c '
		log() { :; }
		KIOSK_PROFILE='"$T"'/profile KIOSK_SCALE=1 KIOSK_NO_SANDBOX=1 browser_gl='"$1"' KIOSK_BROWSER_GL_FLAGS="'"$2"'" KIOSK_DISABLE_FEATURES="'"$3"'"
		. '"$T"'/browser.sh
		echo "$@"' 2>&1; }
f=$(bflags 1 "--fake-gl-flag --fake-two" "FakeFeature")
case " $f " in *" --ignore-gpu-blocklist --fake-gl-flag --fake-two "*) ok "GPU browser: the flags of the hook follow --ignore-gpu-blocklist";; *) bad "GPU browser flags: $f";; esac
case "$f" in *--disable-features=*,FakeFeature*) ok "the disabled features of the hook reach --disable-features";; *) bad "disabled features: $f";; esac
case "$f" in *--disable-gpu-compositing*) bad "GPU browser: software flags";; *) ok "GPU browser: GPU compositing stays on";; esac
f=$(bflags 0 "--fake-gl-flag" "")
case "$f" in *--disable-gpu-compositing*) ok "software browser: GPU compositing off";; *) bad "software browser flags: $f";; esac
case "$f" in *--fake-gl-flag*|*--ignore-gpu-blocklist*) bad "software browser: GPU flags: $f";; *) ok "software browser: the GPU flags stay out";; esac
# name order, only *.sh, and every safe file runs
H=$T/h3; mkhooks "$H"
hk "$H" 10-a.sh 'order=a'
hk "$H" 20-b.sh 'order="${order:-}b"; log "order=$order"'
hk "$H" 15-note.txt 'log "text file ran"'
out=$(HOOKDIR=$H sel "$T/drmh" "$BOARDA")
echo "$out" | grep -q "^log: order=ab$" && ok "hooks run in name order" || bad "hook order: $out"
echo "$out" | grep -q "text file ran" && bad "a file that does not end in .sh ran" || ok "a file that does not end in .sh is ignored"
# a hook that is not safe is skipped, and the others still run
H=$T/h4; mkhooks "$H"
hk "$H" 10-open.sh 'log "world-writable hook ran"'; chmod 666 "$H/10-open.sh"
hk "$H" 11-group.sh 'log "group-writable hook ran"'; chmod 664 "$H/11-group.sh"
hk "$H" 12-bad.sh 'if then fi ('
printf 'log "symlink hook ran"\n' > "$T/h4-real.sh"; chmod 644 "$T/h4-real.sh"; ln -s "$T/h4-real.sh" "$H/13-link.sh"
hk "$H" 40-good.sh 'log "good hook ran"'
out=$(HOOKDIR=$H sel "$T/drmh" "$BOARDA")
echo "$out" | grep -q "world-writable hook ran" && bad "a world-writable hook ran" || ok "a world-writable hook is skipped"
echo "$out" | grep -q "^log: hook $H/10-open.sh skipped: root must own the file" && ok "the skip of a world-writable hook has one log line" || bad "no skip line for 10-open.sh: $out"
echo "$out" | grep -q "group-writable hook ran" && bad "a group-writable hook ran" || ok "a group-writable hook is skipped"
echo "$out" | grep -q "^log: hook $H/12-bad.sh skipped: syntax error" && ok "a hook with a syntax error is skipped with a log line" || bad "no skip line for 12-bad.sh: $out"
echo "$out" | grep -q "symlink hook ran" && bad "a symbolic link ran as a hook" || ok "a symbolic link is skipped"
echo "$out" | grep -q "^log: good hook ran$" && ok "a safe hook runs after the skipped ones" || bad "good hook: $out"
echo "$out" | grep -q "^comp_gl=1 browser_gl=1 " && ok "the skipped hooks changed nothing" || bad "skipped hooks: $out"
# the owner must be root: no hook runs when another user owns the folder
H=$T/h5; mkhooks "$H"
hk "$H" 10-owner.sh 'log "owner hook ran"'
out=$(HOOKUID=$(( $(id -u) + 1 )) HOOKDIR=$H sel "$T/drmh" "$BOARDA")
echo "$out" | grep -q "owner hook ran" && bad "a hook ran with the wrong owner" || ok "a hook that root does not own is skipped"
echo "$out" | grep -q "^log: hooks in $H skipped: root must own the folder" && ok "a folder that root does not own: one log line" || bad "no skip line for the folder: $out"
chmod 777 "$H"
out=$(HOOKDIR=$H sel "$T/drmh" "$BOARDA")
echo "$out" | grep -q "owner hook ran" && bad "a hook ran from a world-writable folder" || ok "a world-writable folder is skipped"
echo "$out" | grep -q "^log: hooks in $H skipped: root must own the folder" && ok "a world-writable folder: one log line" || bad "no skip line for the writable folder: $out"
chmod 755 "$H"
# no folder and an empty folder: nothing changes
out=$(HOOKDIR=$T/no-such-folder sel "$T/drmh" "$BOARDA")
echo "$out" | grep -q "^comp_gl=1 browser_gl=1 " && ! echo "$out" | grep -q "skipped" && ok "no kiosk.d folder: the choice of the script stands" || bad "no folder: $out"
H=$T/h6; mkhooks "$H"
out=$(HOOKDIR=$H sel "$T/drmh" "$BOARDA")
echo "$out" | grep -q "^comp_gl=1 browser_gl=1 " && ! echo "$out" | grep -q "skipped" && ok "an empty kiosk.d folder: the choice of the script stands" || bad "empty folder: $out"
# a KIOSK_GPU value that only a hook knows
out=$(sel "$T/drmh" "$BOARDA" fakemode)
echo "$out" | grep -q "^comp_gl=1 browser_gl=1 " && ok "a KIOSK_GPU value that no hook knows counts as auto" || bad "unknown KIOSK_GPU: $out"
H=$T/h7; mkhooks "$H"
hk "$H" 10-mode.sh 'if [ "$KIOSK_GPU" = fakemode ]; then KIOSK_GL_COMPOSITOR=1; KIOSK_GL_BROWSER=0; log "fakemode: software browser"; fi'
out=$(HOOKDIR=$H sel "$T/drmh" "$BOARDA" fakemode)
echo "$out" | grep -q "^log: fakemode: software browser$" && echo "$out" | grep -q "^comp_gl=1 browser_gl=0 " && ok "a hook adds a KIOSK_GPU mode" || bad "hook mode: $out"
out=$(HOOKDIR=$H sel "$T/drmh" "$BOARDA" auto)
echo "$out" | grep -q "fakemode" && bad "the hook mode ran for KIOSK_GPU=auto" || ok "the hook mode stays off for the other modes"
# the pixman note comes after the hooks
mkdrm "$T/drmx" card2:seconddrm render:secondgpu
out=$(sel "$T/drmx" "$T/board-anyrender.sh")
echo "$out" | grep -q "^log: GPU /dev/dri/renderD128 present but display is seconddrm: using pixman" && ok "a render node and a display driver of another board: pixman, with a note" || bad "pixman note: $out"
H=$T/h8; mkhooks "$H"
hk "$H" 10-gl.sh 'KIOSK_GL_COMPOSITOR=1'
out=$(HOOKDIR=$H sel "$T/drmx" "$T/board-anyrender.sh")
echo "$out" | grep -q "using pixman" && bad "pixman note after a hook turned GLES on" || ok "no pixman note when a hook turns GLES on"
echo "$out" | grep -q "WLR_RENDERER=gles2" && ok "a hook turns GLES on in the compositor" || bad "hook GLES on: $out"

echo "== tsx-config apply =="
CFG=$T/panel.conf; FX=$T/fixture
mkdir -p "$FX/etc/apk" "$FX/etc/tsx" "$FX/root" "$FX/var/lib/kiosk"
echo 'root:!:19000:0:99999:7:::' > "$FX/etc/shadow"
printf 'https://dl-cdn.alpinelinux.org/alpine/v3.24/main\nhttps://dl-cdn.alpinelinux.org/alpine/v3.24/community\n' > "$FX/etc/apk/repositories"
BB=$T/bb; mkdir -p "$BB"; for a in sed grep cmp head cut mv chmod cat rm; do ln -sf "$(command -v busybox)" "$BB/$a"; done
cfg_set() { TSX_BOARD_CONF=$BOARDA TSX_CONF="$CFG" busybox sh "$(P usr/local/sbin/tsx-config)" set "$@" >/dev/null; }
cfg_apply() { # BOARDFILE RUNDIR
	PATH="$BB:$PATH" TSX_BOARD_CONF=$1 TSX_CONF="$CFG" TSX_RUN="$2" TSX_STATE_DIR="$FX/var/lib/tsx" TSX_APPLY_PREFIX="$FX" TSX_APPLY_ALLOW_NONROOT=1 \
	busybox sh "$(P usr/local/sbin/tsx-config)" apply 2>&1; }
cfg_set PANEL_NAME FAKE-100-TEST; cfg_set APK_URL https://tsx-aports.example.org
cfg_set BT_MAC 02:00:00:00:00:01
out=$(cfg_apply "$BOARDA" "$FX/run")
eq "$(sed -n 2,3p "$FX/etc/apk/repositories" | tr '\n' ' ')" "https://tsx-aports.example.org/v3.24/common https://tsx-aports.example.org/v3.24/fake " "the repository category comes from the board file"
grep -qE "$REAL|second" "$FX/etc/apk/repositories" && bad "a name of real hardware or of board B in the repositories" || ok "no name of real hardware or of board B in the repositories"
grep -qx 'PROXY="on"' "$FX/run/tsx/bt.conf" && ok "an empty BT_PROXY follows TSX_BT_PROXY_DEFAULT of the board" || bad "bt.conf: $(cat "$FX/run/tsx/bt.conf")"
grep -qx 'MAC=""' "$FX/run/tsx/bt.conf" && ok "BT_MAC is left out when the board cannot set it" || bad "bt.conf: $(cat "$FX/run/tsx/bt.conf")"
case "$out" in *"BT_MAC=02:00:00:00:00:01 is set, but this board takes the Bluetooth address from the controller"*) ok "BT_MAC: a warning says why";; *) bad "BT_MAC warning: $out";; esac
head -n 1 "$CFG" | grep -q 'fake panel configuration' && ok "the panel.conf header names the family" || bad "panel.conf header: $(head -n 1 "$CFG")"
# board B takes another category, keeps BT_MAC and has the proxy off
out=$(cfg_apply "$BOARDB" "$FX/runb")
eq "$(sed -n 2,3p "$FX/etc/apk/repositories" | tr '\n' ' ')" "https://tsx-aports.example.org/v3.24/common https://tsx-aports.example.org/v3.24/second " "board B: its own repository category"
grep -qx 'MAC="02:00:00:00:00:01"' "$FX/runb/tsx/bt.conf" && grep -qx 'PROXY="off"' "$FX/runb/tsx/bt.conf" && ok "board B: BT_MAC kept, proxy off" || bad "board B bt.conf: $(cat "$FX/runb/tsx/bt.conf")"

echo "== tsx-mqtt (dry run) =="
mkdir -p "$T/mq/run" "$T/mq/bin"
printf 'NODE_ID=tsx-kiosk\nDEVICE_NAME=TSX test\n' > "$T/mq/mqtt.conf"
mkdir -p "$T/mq/asound/FakeCard"
# tsx-mqtt asks tsx-panelctl whether the sound card of the board is there
printf '#!/bin/sh\nexec sh "%s" "$@"\n' "$(P usr/local/sbin/tsx-panelctl)" > "$T/mq/bin/tsx-panelctl"; chmod +x "$T/mq/bin/tsx-panelctl"
mq() { echo | PATH=$T/mq/bin:$PATH TSX_BOARD_CONF=$1 TSX_MQTT_DRY=1 TSX_MQTT_CONF=$T/mq/mqtt.conf TSX_RUN_DIR=$T/mq/run TSX_ASOUND_DIR=$T/mq/asound sh "$(P usr/local/sbin/tsx-mqtt)" 2>&1; }
out=$(mq "$BOARDA")
echo "$out" | grep -q '"mdl":"FAKE-100 (mainline Linux)"' && ok "the device model comes from the board file" || bad "mdl: $(echo "$out" | grep -m1 mdl)"
echo "$out" | grep -q 'number/tsx-kiosk/volume/config' && ok "the volume entity follows the sound card of the board (FakeCard)" || bad "no volume entity"
out=$(mq "$BOARDB")
echo "$out" | grep -q '"mdl":"SECOND-200 (mainline Linux)"' && ok "board B: the model comes from tsx_board_ha_model" || bad "mdl on board B: $(echo "$out" | grep -m1 mdl)"
echo "$out" | grep -q 'number/tsx-kiosk/volume/config' && bad "the volume entity exists without the sound card of board B" || ok "no volume entity without the sound card of the board"

echo "== tsx-autoupdate =="
BIN=$(P usr/local/sbin/tsx-autoupdate)
TSX_BOARD_CONF=$BOARDA sh "$BIN" __needs_reboot "tsx-fake-kernel-lts"; eq $? 0 "the kernel package of the board needs a reboot"
TSX_BOARD_CONF=$BOARDA sh "$BIN" __needs_reboot "tsx-second-kernel-lts"; eq $? 1 "the kernel package of another family does not"
TSX_BOARD_CONF=$BOARDB sh "$BIN" __needs_reboot "tsx-second-kernel-lts"; eq $? 0 "board B: its own kernel package needs a reboot"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo "PASS test-board-fake" || { echo "FAIL test-board-fake"; exit 1; }
