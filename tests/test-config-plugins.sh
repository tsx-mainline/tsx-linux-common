#!/bin/bash
# Host test: the plugins of tsx-config, the folder config.d (docs/layout.md
# "Plugin folders"). The test uses the fake plugin of the made-up board
# (tests/boards/fake/config.d/fakeopt.sh) and some plugins that the test
# writes. It runs the script of the panel under busybox ash, against a
# throwaway panel.conf. It checks:
#  - a key of a plugin: get, set, validate, unset, show (a secret is masked)
#  - the check of the plugin for a part that is missing (REASON of hw.conf)
#  - apply: the override file of the plugin and the restart signatures
#  - the trust rules: owner, write bits, links, the name, a broken file
#  - a key that a plugin may not take, and a key that no plugin knows
#  - the folder next to the script (a host run from a checkout)
set -uo pipefail
# The made-up board for the scripts that read a board file.
. "$(dirname "$0")/lib/board.sh"
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$HERE/base/usr/local/sbin/tsx-config"
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-config-plugins: no busybox on this host"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
ME=$(id -u)
CFG="$W/panel.conf"
FX="$W/fixture"
RUNDIR="$FX/run/tsx"
mkdir -p "$FX/etc" "$FX/root" "$FX/var/lib/kiosk" "$RUNDIR"
echo 'root:!:19000:0:99999:7:::' > "$FX/etc/shadow"
N=0 F=0
ok() { echo "  ok: $*"; N=$((N+1)); }
bad() { echo "  FAIL: $*"; F=$((F+1)); }

# The plugin folders. Copies with fixed modes, so that a checkout with another umask does not matter.
newdir() { mkdir -p "$W/pd/$1"; chmod 755 "$W/pd/$1"; }
newfile() { cp "$2" "$W/pd/$1/$(basename "$2")"; chmod 644 "$W/pd/$1/$(basename "$2")"; }
newdir good; newfile good "$HERE/tests/boards/fake/config.d/fakeopt.sh"
PD="$W/pd/good"
newdir empty
HW="$W/hw.conf"; : > "$HW"

run() { env TSX_CONF="$CFG" TSX_CONFIG_PLUGIN_DIR="${PLUGDIR:-$PD}" TSX_PLUGIN_OWNER_UID="${OWNER:-$ME}" TSX_HW_CONF="$HW" busybox sh "$SCRIPT" "$@"; }
apply_() { env TSX_CONF="$CFG" TSX_RUN="$FX/run" TSX_STATE_DIR="$FX/var/lib/tsx" TSX_APPLY_PREFIX="$FX" TSX_APPLY_ALLOW_NONROOT=1 \
	TSX_CONFIG_PLUGIN_DIR="${PLUGDIR:-$PD}" TSX_PLUGIN_OWNER_UID="${OWNER:-$ME}" busybox sh "$SCRIPT" apply; }

busybox sh -n "$SCRIPT" && ok "busybox sh -n" || bad "busybox sh -n"
busybox sh -n "$PD/fakeopt.sh" && ok "busybox sh -n of the fake plugin" || bad "busybox sh -n of the fake plugin"

echo "== a key of a plugin: get, set, validate, unset =="
run set FAKEOPT low >/dev/null 2>&1 && ok "set FAKEOPT low" || bad "set FAKEOPT low"
[ "$(run get FAKEOPT)" = low ] && ok "get returns the value" || bad "get FAKEOPT: $(run get FAKEOPT 2>&1)"
for v in off low high; do run validate FAKEOPT "$v" && ok "FAKEOPT=$v is valid" || bad "FAKEOPT=$v rejected"; done
for v in "" on 1 Low; do run validate FAKEOPT "$v" 2>/dev/null && bad "FAKEOPT='$v' accepted" || ok "FAKEOPT='$v' is invalid"; done
out=$(run set FAKEOPT bogus 2>&1) && bad "set with an invalid value worked" || ok "set with an invalid value fails ($out)"
[ "$(run get FAKEOPT)" = low ] && ok "the invalid value did not change the key" || bad "FAKEOPT changed to $(run get FAKEOPT)"
run unset FAKEOPT 2>/dev/null && ! run get FAKEOPT >/dev/null 2>&1 && ok "unset removes the key" || bad "unset FAKEOPT"
run validate FAKEOPT_TOKEN abcdefgh12 && ok "a second key of the plugin: valid value" || bad "FAKEOPT_TOKEN rejected"
run validate FAKEOPT_TOKEN short 2>/dev/null && bad "a short token accepted" || ok "a second key of the plugin: invalid value"

echo "== show masks a secret key of a plugin =="
run set FAKEOPT high 2>/dev/null; run set FAKEOPT_TOKEN abcdefgh12 2>/dev/null
SHOWN=$(run show 2>/dev/null)
printf '%s\n' "$SHOWN" | grep -qx 'FAKEOPT=high' && ok "show prints a key of a plugin" || bad "show: $SHOWN"
printf '%s\n' "$SHOWN" | grep -qx 'FAKEOPT_TOKEN=\*\*\*\*\*\*\*\*' && ok "show masks the secret key of the plugin" || bad "show: $SHOWN"
printf '%s\n' "$SHOWN" | grep -q abcdefgh12 && bad "show printed the secret" || ok "show never prints the secret"

echo "== the part is missing: the plugin gives the reason =="
printf 'FAKEOPT=no\nREASON=the fake board has none\n' > "$HW"
out=$(run set FAKEOPT high 2>&1) && ok "set still saves the key" || bad "set failed: $out"
case "$out" in *"FAKEOPT=high is saved, but this panel has no fake option (the fake board has none)"*) ok "set warns with the reason of hw.conf";; *) bad "set warning: $out";; esac
out=$(run show 2>&1 >/dev/null)
case "$out" in *"# WARNING: FAKEOPT=high is set, but this panel has no fake option (the fake board has none)"*) ok "show warns with the reason";; *) bad "show warning: $out";; esac
: > "$HW"
out=$(run set FAKEOPT high 2>&1); [ -z "$out" ] && ok "no warning when the part is there" || bad "unexpected output: $out"

echo "== apply: the override file and the restart signatures =="
rm -f "$CFG"; run set FAKEOPT low 2>/dev/null; run set FAKEOPT_TOKEN abcdefgh12 2>/dev/null
apply_ >/dev/null 2>&1 && ok "apply exits 0" || bad "apply failed"
grep -qx 'FAKEOPT="low"' "$RUNDIR/fakeopt.conf" 2>/dev/null && ok "apply wrote the override file of the plugin" || bad "fakeopt.conf: $(cat "$RUNDIR/fakeopt.conf" 2>&1)"
[ "$(stat -c %a "$RUNDIR/fakeopt.conf" 2>/dev/null)" = 644 ] && ok "... with the mode that the plugin chose" || bad "mode of fakeopt.conf"
case "$(cat "$RUNDIR/.esphome-sig")" in *"|low") ok "the signature of tsx-esphome ends with the text of the plugin";; *) bad "esphome sig: $(cat "$RUNDIR/.esphome-sig")";; esac
case "$(cat "$RUNDIR/.voice-sig")" in *"|low") ok "the signature of tsx-voice ends with the text of the plugin";; *) bad "voice sig: $(cat "$RUNDIR/.voice-sig")";; esac
SIG_LOW=$(cat "$RUNDIR/.esphome-sig")
run set FAKEOPT high 2>/dev/null; apply_ >/dev/null 2>&1
SIG_HIGH=$(cat "$RUNDIR/.esphome-sig")
[ "$(cat "$RUNDIR/.esphome-sig")" != "$SIG_LOW" ] && ok "a new value gives a new signature" || bad "the signature did not change"
[ "$(cat "$RUNDIR/.esphome-sig")" = "${SIG_LOW%low}high" ] && ok "... and only the text of the plugin changed" || bad "signature: $(cat "$RUNDIR/.esphome-sig")"
printf 'FAKEOPT=no\nREASON=the fake board has none\n' > "$RUNDIR/hw.conf"
out=$(apply_ 2>&1)
grep -qx 'FAKEOPT="off"' "$RUNDIR/fakeopt.conf" && ok "a missing part: the plugin writes off" || bad "fakeopt.conf: $(cat "$RUNDIR/fakeopt.conf")"
case "$out" in *"FAKEOPT=high is set, but this panel has no fake option (the fake board has none). apply leaves it out"*) ok "... and apply warns with the reason";; *) bad "apply output: $out";; esac
case "$(cat "$RUNDIR/.esphome-sig")" in *"|off") ok "... and the signature says off";; *) bad "esphome sig: $(cat "$RUNDIR/.esphome-sig")";; esac
rm -f "$RUNDIR/hw.conf"

echo "== apply without a plugin: a key that this panel does not use =="
PLUGDIR="$W/pd/empty"
FO_BEFORE=$(cat "$RUNDIR/fakeopt.conf")
out=$(apply_ 2>&1); rc=$?
[ $rc = 0 ] && ok "apply exits 0" || bad "apply failed: $out"
[ "$(printf '%s\n' "$out" | grep -c 'panel.conf has the key FAKEOPT,')" = 1 ] && ok "one warning for the key of the missing plugin" || bad "apply output: $out"
case "$out" in *"WARNING: panel.conf has the key FAKEOPT, which this panel does not use. apply ignores it"*) ok "... with the text of the warning";; *) bad "apply output: $out";; esac
printf '%s\n' "$out" | grep -q 'panel.conf has the key FAKEOPT_TOKEN' && ok "... also for the second key" || bad "no warning for FAKEOPT_TOKEN"
[ "$(cat "$RUNDIR/fakeopt.conf")" = "$FO_BEFORE" ] && ok "apply does not touch the override file of the missing plugin" || bad "fakeopt.conf changed"
[ "$(cat "$RUNDIR/.esphome-sig")" = "${SIG_HIGH%|high}" ] && ok "the signature has no text of the plugin" || bad "signature: $(cat "$RUNDIR/.esphome-sig")" 
echo 'FAKEOPT="low"' > "$W/only.conf"
out=$(env TSX_CONF="$W/only.conf" TSX_RUN="$FX/run" TSX_STATE_DIR="$FX/var/lib/tsx" TSX_APPLY_PREFIX="$FX" TSX_APPLY_ALLOW_NONROOT=1 TSX_CONFIG_PLUGIN_DIR="$W/pd/empty" busybox sh "$SCRIPT" apply 2>&1)
[ "$(printf '%s\n' "$out" | grep -c 'panel.conf has the key')" = 1 ] && ok "a panel.conf with only that key: one warning" || bad "apply output: $out"
PLUGDIR="$W/pd/empty" run get FAKEOPT >/dev/null 2>&1 && bad "get of an unknown key worked" || ok "get of the key of a missing plugin fails"
PLUGDIR="$W/pd/empty" run set FAKEOPT low >/dev/null 2>&1 && bad "set of the key of a missing plugin worked" || ok "set of the key of a missing plugin fails"
PLUGDIR="$W/pd/empty" run validate FAKEOPT low 2>/dev/null && bad "validate accepted the key of a missing plugin" || ok "validate refuses the key of a missing plugin"
unset PLUGDIR

echo "== a plugin with only the required parts =="
cat > "$W/minimal.sh" <<'EOF'
# a plugin with no cfg_NAME_missing and no cfg_NAME_apply
CFG_MINIMAL_KEYS="MINI_LEVEL"
cfg_minimal_valid() { case "$2" in [0-9]|[0-9][0-9]) return 0;; esac; return 1; }
EOF
newdir min; newfile min "$W/minimal.sh"
PLUGDIR="$W/pd/min"
run set MINI_LEVEL 12 >/dev/null 2>&1 && ok "set works" || bad "set MINI_LEVEL"
run validate MINI_LEVEL 123 2>/dev/null && bad "an invalid value accepted" || ok "an invalid value is refused"
out=$(run show 2>&1); [ "$(printf '%s\n' "$out" | grep -c '^MINI_LEVEL=12$')" = 1 ] && ok "show works" || bad "show: $out"
out=$(apply_ 2>&1); rc=$?
[ $rc = 0 ] && ok "apply works. The plugin writes nothing" || bad "apply failed: $out"
case "$(cat "$RUNDIR/.esphome-sig")" in *"|") ok "the signature gets an empty text for the plugin";; *) bad "signature: $(cat "$RUNDIR/.esphome-sig")";; esac
unset PLUGDIR; rm -f "$CFG"

echo "== the trust rules =="
# the folder
newdir gw; newfile gw "$PD/fakeopt.sh"; chmod 775 "$W/pd/gw"
out=$(PLUGDIR="$W/pd/gw" run validate FAKEOPT low 2>&1) && bad "a folder that the group can write: the plugin loaded" || ok "a folder that the group can write: no plugin"
case "$out" in *"no plugin loaded: $W/pd/gw can be changed by its group or by others"*) ok "... one line says why";; *) bad "output: $out";; esac
newdir ow; newfile ow "$PD/fakeopt.sh"; chmod 757 "$W/pd/ow"
PLUGDIR="$W/pd/ow" run validate FAKEOPT low >/dev/null 2>&1 && bad "a folder that others can write: the plugin loaded" || ok "a folder that others can write: no plugin"
# the owner
out=$(OWNER=$((ME + 1)) run validate FAKEOPT low 2>&1) && bad "another owner id: the plugin loaded" || ok "another owner id: no plugin"
case "$out" in *"is not owned by user $((ME + 1))"*) ok "... one line says why";; *) bad "output: $out";; esac
if [ "$ME" != 0 ]; then
	out=$(env -u TSX_PLUGIN_OWNER_UID TSX_CONF="$CFG" TSX_CONFIG_PLUGIN_DIR="$PD" TSX_HW_CONF="$HW" busybox sh "$SCRIPT" validate FAKEOPT low 2>&1) \
		&& bad "the default owner: a file of another user than root loaded" || ok "the default owner is root: a file of another user does not load"
	case "$out" in *"is not owned by user 0"*) ok "... one line says why";; *) bad "output: $out";; esac
else
	echo "  skip: the default owner check needs a user that is not root"
fi
# a file
newdir fw; newfile fw "$PD/fakeopt.sh"; chmod 664 "$W/pd/fw/fakeopt.sh"
out=$(PLUGDIR="$W/pd/fw" run validate FAKEOPT low 2>&1) && bad "a file that the group can write: the plugin loaded" || ok "a file that the group can write: skipped"
case "$out" in *"plugin $W/pd/fw/fakeopt.sh skipped: the file can be changed by its group or by others"*) ok "... one line says why";; *) bad "output: $out";; esac
chmod 646 "$W/pd/fw/fakeopt.sh"
PLUGDIR="$W/pd/fw" run validate FAKEOPT low >/dev/null 2>&1 && bad "a file that others can write: the plugin loaded" || ok "a file that others can write: skipped"
# a link
newdir ln; ln -s "$PD/fakeopt.sh" "$W/pd/ln/fakeopt.sh"
out=$(PLUGDIR="$W/pd/ln" run validate FAKEOPT low 2>&1) && bad "a link: the plugin loaded" || ok "a link is skipped"
case "$out" in *"the file is not a regular file"*) ok "... one line says why";; *) bad "output: $out";; esac
# one bad file does not stop the next
newdir mix
printf 'CFG_ABAD_KEYS="ABAD"\ncfg_abad_valid() { return 0; }\n' > "$W/pd/mix/abad.sh"; chmod 666 "$W/pd/mix/abad.sh"
newfile mix "$PD/fakeopt.sh"
out=$(PLUGDIR="$W/pd/mix" run validate FAKEOPT low 2>&1) && ok "a file that is skipped does not stop the next plugin" || bad "the next plugin did not load: $out"
PLUGDIR="$W/pd/mix" run validate ABAD x >/dev/null 2>&1 && bad "the key of the skipped file works" || ok "the key of the skipped file is unknown"

echo "== a file that does not load, a bad name, a plugin without its parts =="
newdir broken
printf 'CFG_SYN_KEYS="SYN"\ncfg_syn_valid() { if then; }\n' > "$W/pd/broken/syn.sh"
printf 'CFG_FAIL_KEYS="FAILK"\ncfg_fail_valid() { return 0; }\nfalse\n' > "$W/pd/broken/fail.sh"
printf 'CFG_UNSET_KEYS="UNSETK"\ncfg_unset_valid() { return 0; }\necho "$undefined_variable_of_the_test" >/dev/null\n' > "$W/pd/broken/unset.sh"
printf 'CFG_BADNAME_KEYS="BADNAME"\ncfg_badname_valid() { return 0; }\n' > "$W/pd/broken/Bad-Name.sh"
printf 'CFG_NOKEYS_KEYS=""\ncfg_nokeys_valid() { return 0; }\n' > "$W/pd/broken/nokeys.sh"
printf 'CFG_NOVALID_KEYS="NOVALID"\n' > "$W/pd/broken/novalid.sh"
printf 'CFG_LOWER_KEYS="lower Good_1 1BAD"\ncfg_lower_valid() { return 0; }\n' > "$W/pd/broken/lower.sh"
chmod 644 "$W/pd/broken/"*.sh
newfile broken "$PD/fakeopt.sh"
out=$(PLUGDIR="$W/pd/broken" run show 2>&1 >/dev/null)
for n in syn fail unset Bad-Name nokeys novalid; do
	case "$out" in *"plugin $W/pd/broken/$n.sh skipped"*) ok "the plugin $n is skipped, with a line";; *) bad "no line for $n: $out";; esac
done
case "$out" in *"use lowercase letters, digits and _ in the name"*) ok "a name with a capital letter or a dash is refused";; *) bad "output: $out";; esac
case "$out" in *"it needs CFG_NOVALID_KEYS and cfg_novalid_valid"*) ok "a plugin without cfg_NAME_valid is refused";; *) bad "output: $out";; esac
for k in SYN FAILK UNSETK BADNAME NOVALID; do
	PLUGDIR="$W/pd/broken" run validate $k x >/dev/null 2>&1 && bad "the key $k works" || ok "the key $k of a skipped plugin is unknown"
done
PLUGDIR="$W/pd/broken" run validate FAKEOPT low 2>/dev/null && ok "the good plugin of the same folder works" || bad "the good plugin does not work"
case "$out" in *"the key lower is ignored: use capital letters, digits and _"*"the key 1BAD is ignored"*) ok "a key with a bad name is ignored, with a line";; *) bad "output: $out";; esac
PLUGDIR="$W/pd/broken" run validate Good_1 x >/dev/null 2>&1 && bad "a key with lowercase letters works" || ok "the key Good_1 is refused, because it is no capital name"

echo "== a plugin cannot take a key that is known =="
newdir greedy
cat > "$W/pd/greedy/greedy.sh" <<'EOF'
# a plugin that wants a key of tsx-config and a key of the first plugin
CFG_GREEDY_KEYS="PANEL_NAME FAKEOPT OWN_KEY"
CFG_GREEDY_SECRET_KEYS="PANEL_NAME"
cfg_greedy_valid() { return 0; }
EOF
chmod 644 "$W/pd/greedy/greedy.sh"
newfile greedy "$PD/fakeopt.sh"
PLUGDIR="$W/pd/greedy"
out=$(run show 2>&1 >/dev/null)
case "$out" in *"plugin greedy: the key PANEL_NAME is ignored: it is known already"*) ok "PANEL_NAME stays with tsx-config";; *) bad "output: $out";; esac
case "$out" in *"plugin greedy: the key FAKEOPT is ignored: it is known already"*) ok "the key of the first plugin stays with the first plugin";; *) bad "output: $out";; esac
run validate PANEL_NAME "bad name!" 2>/dev/null && bad "PANEL_NAME takes a bad name" || ok "PANEL_NAME keeps its check"
run validate PANEL_NAME good-name 2>/dev/null && ok "PANEL_NAME keeps its check (valid value)" || bad "PANEL_NAME rejects a good name"
run validate FAKEOPT bogus 2>/dev/null && bad "FAKEOPT lost its check" || ok "FAKEOPT keeps the check of its plugin"
run validate OWN_KEY anything 2>/dev/null && ok "the key that was free works" || bad "OWN_KEY does not work"
run set PANEL_NAME visible-name >/dev/null 2>&1; run show 2>/dev/null | grep -qx 'PANEL_NAME=visible-name' && ok "the plugin did not make PANEL_NAME a secret" || bad "PANEL_NAME is masked"
unset PLUGDIR

echo "== the folder next to the script (a host run from a checkout) =="
if [ "$ME" = 0 ]; then
	echo "  skip: root does not trust this folder"
elif [ -e /usr/local/lib/tsx/config.d ] || [ -e /usr/local/lib/tsx/board.sh ]; then
	echo "  skip: this host has /usr/local/lib/tsx"
else
	mkdir -p "$W/co/sbin" "$W/co/lib/tsx/config.d"
	cp "$SCRIPT" "$W/co/sbin/tsx-config"; chmod 755 "$W/co/sbin/tsx-config"
	cp "$TSX_BOARD_CONF" "$W/co/lib/tsx/board.sh"
	cp "$PD/fakeopt.sh" "$W/co/lib/tsx/config.d/fakeopt.sh"
	chmod 666 "$W/co/lib/tsx/config.d/fakeopt.sh"
	co() { env -u TSX_BOARD_CONF -u TSX_CONFIG_PLUGIN_DIR -u TSX_PLUGIN_OWNER_UID TSX_CONF="$W/co.conf" TSX_HW_CONF="$HW" busybox sh "$W/co/sbin/tsx-config" "$@"; }
	co set FAKEOPT high >/dev/null 2>&1 && ok "the plugin next to the script works for a user that is not root" || bad "set: $(co set FAKEOPT high 2>&1)"
	[ "$(co get FAKEOPT 2>/dev/null)" = high ] && ok "... get returns the value" || bad "get FAKEOPT"
	env TSX_CONF="$W/co.conf" TSX_CONFIG_PLUGIN_DIR="$W/pd/empty" TSX_PLUGIN_OWNER_UID="$ME" TSX_BOARD_CONF="$TSX_BOARD_CONF" TSX_HW_CONF="$HW" \
		busybox sh "$W/co/sbin/tsx-config" validate FAKEOPT low >/dev/null 2>&1 \
		&& bad "TSX_CONFIG_PLUGIN_DIR did not replace the folder next to the script" || ok "TSX_CONFIG_PLUGIN_DIR replaces the folder next to the script"
fi

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-config-plugins || echo FAIL test-config-plugins
exit $F
