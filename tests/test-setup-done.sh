#!/bin/bash
# Host test for the setup state of the panel (setup-state.sh of tsx-base):
# configured <=> the marker /data/tsx/setup-done exists. The test covers:
#  - setup-state.sh: the rule, the atomic and durable write (mode 644, one
#    line, no temporary file left), a leftover temporary file counts for
#    nothing, a folder that cannot be searched counts as configured
#  - tsx-config setup-done and setup-state (root only), and that no key of
#    panel.conf (SSH_AUTHORIZED_KEY, KIOSK_URL, HA_URL, ...) writes the marker
#  - the migration of tsx-setup-helper (migrate): each case of the rule of the
#    earlier releases (with and without a kiosk) -> configured or not; with the
#    code of 7aafeb2 as the reference when git has that commit; the stamp
#    stops the migration; a power cut between the files; a panel.conf that
#    cannot be read, a failed tsx-config show and a failed old rule write
#    nothing
#  - the contract of the RAM installer of uc-pxx: panel.conf with only
#    SSH_AUTHORIZED_KEY (mode 600) and the stamp setup-v2 boots UNCONFIGURED:
#    apply adds the key for root, the pairing code works, the LAN listener is
#    on, screen.json (the setup bar) is there. A save of the page then writes
#    the marker and closes all of it.
#  - a fresh panel (no panel.conf, no stamp) is unconfigured; a panel.conf of
#    an earlier release that the old rule calls configured is configured
#  - tsx-setupd: an answer of the helper that is not "done" or "open" counts as
#    configured
#  - the init script of tsx-setup-helper runs the migration before tsx-setupd
# The test runs the real scripts with busybox sh and python3, as this user. It
# never uses the panel, a container or root.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
. "$(dirname "$0")/lib/board.sh"
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tests/lib/paths.sh"
TSXCONFIG=$(P usr/local/sbin/tsx-config)
HELPER=$(P usr/local/sbin/tsx-setup-helper)
SETUPD=$(P usr/local/sbin/tsx-setupd)
SSTATE=$(P usr/local/lib/tsx/setup-state.sh)
OLDRULE=$(P usr/local/lib/tsx/setup_old_rule.py)
command -v busybox >/dev/null 2>&1 || { echo "SKIPPED test-setup-done: no busybox on this host"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIPPED test-setup-done: no python3 on this host"; exit 0; }

T=$(mktemp -d)
PIDS=
cleanup() {
	for p in $PIDS; do kill "$p" 2>/dev/null; done
	chmod -R u+rwx "$T" 2>/dev/null
	[ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"
}
trap cleanup EXIT
N=0 F=0
ok() { echo "  ok: $*"; N=$((N + 1)); }
bad() { echo "  FAIL: $*"; F=$((F + 1)); }
ROOT=0; [ "$(id -u)" = 0 ] && ROOT=1

mkdir -p "$T/bin"
cat > "$T/bin/tsx-config" <<EOF
#!/bin/sh
exec busybox sh "$TSXCONFIG" "\$@"
EOF
cat > "$T/bin/rc-service" <<EOF
#!/bin/sh
case "\$2" in status) exit 1;; *) exit 0;; esac
EOF
chmod +x "$T/bin/tsx-config" "$T/bin/rc-service"
KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGVoZHRlc3RrZXl0ZXN0a2V5dGVzdGtleXRlc3Rr installer@test"

echo "== syntax =="
busybox sh -n "$SSTATE" && ok "busybox sh -n setup-state.sh" || bad "setup-state.sh syntax"
busybox sh -n "$HELPER" && ok "busybox sh -n tsx-setup-helper" || bad "tsx-setup-helper syntax"
busybox sh -n "$HERE/setup/etc/init.d/tsx-setup-helper" && ok "busybox sh -n init.d/tsx-setup-helper" || bad "init.d syntax"
python3 -c 'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' "$OLDRULE" "$T/oldrule.pyc" \
	&& ok "py_compile setup_old_rule.py" || bad "py_compile setup_old_rule.py"

# ---- 1. setup-state.sh ---------------------------------------------------------
echo "== setup-state.sh: the rule and the write =="
D="$T/lib"; mkdir -p "$D"
lib() { TSX_CONF="$D/panel.conf" busybox sh -c '. "$1"; shift; "$@"' sh "$SSTATE" "$@"; }
lib tsx_setup_done && bad "no marker: configured" || ok "no marker: not configured"
: > "$D/.setup-done.tmp.4242"
lib tsx_setup_done && bad "a leftover temporary file counts as the marker" || ok "a leftover temporary file of the marker counts for nothing"
(umask 077; lib tsx_setup_write "$D/setup-done" done) && ok "tsx_setup_write exits 0" || bad "tsx_setup_write failed"
[ "$(cat "$D/setup-done")" = done ] && [ "$(wc -l < "$D/setup-done")" = 1 ] && ok "the marker has one line" || bad "marker content: $(od -c "$D/setup-done" | head -3)"
[ "$(stat -c %a "$D/setup-done")" = 644 ] && ok "the marker has mode 644 (also with umask 077)" || bad "marker mode $(stat -c %a "$D/setup-done")"
ls -A "$D" | grep -q tmp && bad "a temporary file stays: $(ls -A "$D")" || ok "no temporary file stays (also the old leftover is gone)"
lib tsx_setup_done && ok "the marker: configured" || bad "the marker is not seen"
ln -s "$T/nowhere" "$D/link-done"
TSX_SETUP_DONE_FILE="$D/link-done" lib tsx_setup_done && ok "a dangling link as the marker counts as configured (the safe side)" || bad "a dangling link is not seen"
lib tsx_setup_write "$T/new/sub/setup-v2" 2 && [ "$(stat -c %a "$T/new/sub")" = 700 ] && [ "$(cat "$T/new/sub/setup-v2")" = 2 ] \
	&& ok "a missing folder is made with mode 700 (as tsx-config makes the folder of panel.conf)" || bad "new folder: $(stat -c %a "$T/new/sub" 2>&1)"
grep -q 'sync "\$_tsw_t"' "$SSTATE" && grep -q 'sync "\$_tsw_d"' "$SSTATE" && grep -q 'mv -f "\$_tsw_t" "\$_tsw_f"' "$SSTATE" \
	&& ok "the write syncs the file, renames it, and syncs the folder" || bad "the write is not sync, rename, sync"
if [ "$ROOT" = 0 ]; then
	mkdir -p "$T/locked"; chmod 000 "$T/locked"
	TSX_SETUP_DONE_FILE="$T/locked/setup-done" lib tsx_setup_done && ok "a folder that cannot be searched counts as configured" || bad "an unsearchable folder reads as not configured"
	chmod 500 "$T/locked"
	TSX_SETUP_DONE_FILE="$T/locked/setup-done" lib tsx_setup_write "$T/locked/setup-done" done 2>/dev/null && bad "a write into a read-only folder says ok" || ok "a write that cannot be done exits 1"
	[ ! -e "$T/locked/setup-done" ] && ok "and leaves nothing" || bad "a file is left in the read-only folder"
	chmod 700 "$T/locked"
else
	echo "  (root: the unsearchable-folder checks are skipped)"
fi

# ---- 2. tsx-config setup-done / setup-state ----------------------------------------
echo "== tsx-config setup-done and setup-state =="
C="$T/cli"; mkdir -p "$C"
tc() { TSX_CONF="$C/panel.conf" TSX_RUN="$C/run" TSX_APPLY_ALLOW_NONROOT=1 busybox sh "$TSXCONFIG" "$@"; }
if [ "$ROOT" = 0 ]; then
	TSX_CONF="$C/panel.conf" busybox sh "$TSXCONFIG" setup-done >/dev/null 2>&1 && bad "setup-done ran as a user" || ok "setup-done refuses a user that is not root"
	[ ! -e "$C/setup-done" ] && ok "and writes nothing" || bad "setup-done as a user wrote the marker"
	TSX_CONF="$C/panel.conf" busybox sh "$TSXCONFIG" setup-state >/dev/null 2>&1; [ $? = 2 ] && ok "setup-state refuses a user that is not root" || bad "setup-state as a user"
fi
out=$(tc setup-state 2>/dev/null); rc=$?
[ "$out" = unconfigured ] && [ $rc = 1 ] && ok "setup-state: unconfigured, exit 1" || bad "setup-state: '$out' rc $rc"
{ tc setup-state 2>&1 >/dev/null || true; } | grep -q 'setup-v2 is missing' && ok "setup-state says when the stamp is missing" || bad "no note about the missing stamp"
for kv in "SSH_AUTHORIZED_KEY=$KEY" "KIOSK_URL=https://ha.example.org/lovelace/0" "HA_URL=https://ha.example.org:8123" "TZ_NAME=UTC" "PANEL_NAME=panel-1" "UPDATE_MODE=manual"; do
	tc set "${kv%%=*}" "${kv#*=}" >/dev/null 2>&1 || bad "set ${kv%%=*}"
done
mkdir -p "$C/prefix/etc" && echo 'root:!:19000:0:99999:7:::' > "$C/prefix/etc/shadow"
TSX_APPLY_PREFIX="$C/prefix" TSX_STATE_DIR="$C/state" tc apply >/dev/null 2>&1
[ ! -e "$C/setup-done" ] && [ "$(tc setup-state 2>/dev/null)" = unconfigured ] \
	&& ok "SSH_AUTHORIZED_KEY, KIOSK_URL, HA_URL and other keys (set + apply) do not make the panel configured" || bad "a key wrote the marker"
grep -q setup-done "$TSXCONFIG" && ! grep -n 'tsx_setup_write' "$TSXCONFIG" | grep -v 'TSX_SETUP_DONE_FILE" done' | grep -q . \
	&& ok "tsx-config writes the marker in one place only (setup-done)" || bad "tsx-config writes the setup state elsewhere: $(grep -n tsx_setup_write "$TSXCONFIG")"
out=$(tc setup-done 2>&1); rc=$?
[ $rc = 0 ] && [ "$(cat "$C/setup-done")" = done ] && [ "$(stat -c %a "$C/setup-done")" = 644 ] && ok "setup-done writes the marker (one line, mode 644)" || bad "setup-done: rc $rc $out"
echo "$out" | grep -q 'the setup is done' && ok "setup-done says so" || bad "setup-done text: $out"
[ ! -e "$C/setup-v2" ] && ok "setup-done writes only the marker (no stamp)" || bad "setup-done wrote the stamp"
out=$(tc setup-state 2>/dev/null); rc=$?
[ "$out" = configured ] && [ $rc = 0 ] && ok "setup-state: configured, exit 0" || bad "setup-state after setup-done: '$out' rc $rc"
before=$(stat -c %Y.%i "$C/setup-done")
tc setup-done 2>&1 | grep -q 'already' && [ "$(stat -c %Y.%i "$C/setup-done")" = "$before" ] && ok "a second setup-done keeps the marker as it is" || bad "second setup-done"
tc setup-done extra >/dev/null 2>&1; [ $? = 2 ] && ok "setup-done takes no argument" || bad "setup-done with an argument"

# ---- 3. the migration of tsx-setup-helper ----------------------------------------
echo "== the migration: the rule of the earlier releases =="
# The code of 7aafeb2 (0.3.13_pre20261111) is the reference, when git has it.
OLD=
if git -C "$HERE" cat-file -e 7aafeb2^{commit} 2>/dev/null; then
	mkdir -p "$T/old" && git -C "$HERE" archive 7aafeb2 setup base | tar -x -C "$T/old" && OLD="$T/old"
fi
[ -n "$OLD" ] || echo "  (git has no commit 7aafeb2 here: no compare with the old tsx-setupd)"
cp -r "$TSX_BOARD_DIR/config.d" "$T/plugins"; chmod 755 "$T/plugins"; chmod 644 "$T/plugins"/*
# mig NAME EXPECT KIOSK PANELCONF ETCKIOSK DEFAULTSKIOSK [SETUPCONF]
#   KIOSK: on, off or auto (no TSX_SETUP_KIOSK in the environment)
#   PANELCONF, ETCKIOSK, DEFAULTSKIOSK, SETUPCONF: the text of the file, or - (no file)
mig() {
	local name=$1 want=$2 kiosk=$3 pc=$4 ek=$5 dk=$6 sc=${7:--} d="$T/m/$1"
	mkdir -p "$d/defaults"
	[ "$pc" = - ] || printf '%s\n' "$pc" > "$d/panel.conf"
	[ "$ek" = - ] || printf '%s\n' "$ek" > "$d/kiosk.conf"
	[ "$dk" = - ] || printf '%s\n' "$dk" > "$d/defaults/kiosk.conf"
	[ "$sc" = - ] || printf '%s\n' "$sc" > "$d/setup.conf"
	local envk=(env -u TSX_SETUP_KIOSK)
	[ "$kiosk" = auto ] || envk=(env TSX_SETUP_KIOSK="$kiosk")
	local e=(TSX_CONF="$d/panel.conf" TSX_KIOSK_CONF="$d/kiosk.conf" TSX_SETUP_CONF="$d/setup.conf"
		TSX_DEFAULTS_DIR="$d/defaults" TSX_CONFIG_PLUGIN_DIR="$T/plugins" TSX_PLUGIN_OWNER_UID="$(id -u)")
	"${envk[@]}" "${e[@]}" TSX_CONFIG_BIN="$T/bin/tsx-config" PATH="$T/bin:$PATH" \
		busybox sh "$HELPER" migrate > "$d/migrate.log" 2>&1
	local rc=$? got=unconfigured
	[ -e "$d/setup-done" ] && got=configured
	if [ $rc = 0 ] && [ "$got" = "$want" ] && [ "$(cat "$d/setup-v2" 2>/dev/null)" = 2 ]; then
		ok "$name: $want, and the stamp"
	else
		bad "$name: want $want, got $got (rc $rc, stamp '$(cat "$d/setup-v2" 2>/dev/null)'): $(cat "$d/migrate.log")"
	fi
	[ "$got" = configured ] && { [ "$(cat "$d/setup-done")" = migrated ] || bad "$name: marker text '$(cat "$d/setup-done")'"; }
	if [ -n "$OLD" ]; then
		# the old tsx-setupd: is_configured_from(tcfg_show()), with the reply that
		# the old tsx-setup-helper gave for "show" (old tsx-config show 2>&1, \1 between the lines)
		local show old
		show=$("${envk[@]}" "${e[@]}" busybox sh "$OLD/base/usr/local/sbin/tsx-config" show 2>&1 | tr '\n' '\1')
		old=$("${envk[@]}" "${e[@]}" TSX_RUN_DIR="$d/run" TSX_SETUP_PLUGIN_DIR="$T/none" TSX_SETUP_NO_ZEROCONF=1 \
			python3 -c 'import sys, importlib.machinery as m
d = m.SourceFileLoader("oldsetupd", sys.argv[1]).load_module()
d.helper_call = lambda line, timeout=None: (True, sys.argv[2]) if line == "show" else (True, "x")
print("configured" if d.is_configured_from(d.tcfg_show()) else "unconfigured")' "$OLD/setup/usr/local/sbin/tsx-setupd" "${show%$'\1'}" 2>"$d/old.err")
		[ "$old" = "$got" ] && ok "$name: the old tsx-setupd (7aafeb2) says $old too" || bad "$name: the old tsx-setupd says '$old' ($(cat "$d/old.err")), the migration $got"
	fi
}
HDR='# /data/tsx/panel.conf: fake panel configuration (tsx-config).
# One KEY="value" setting per line.'
# no kiosk: panel.conf needs a key that tsx-config knows
mig nk-fresh unconfigured off - - -
mig nk-header-only unconfigured off "$HDR" - -
mig nk-tz configured off "$HDR
TZ_NAME=\"UTC\"" - -
mig nk-ssh-key-of-an-old-panel configured off "SSH_AUTHORIZED_KEY=\"$KEY\"" - -
mig nk-empty-value configured off 'TZ_NAME=""' - -
mig nk-unknown-key-only unconfigured off 'NOT_A_KEY="1"' - -
mig nk-plugin-key configured off 'FAKEOPT="low"' - -
mig nk-comment-only unconfigured off '# KIOSK_URL="https://ha.example.org"' - -
mig nk-auto-no-kiosk-defaults configured auto 'TZ_NAME="UTC"' 'KIOSK_URL="https://ha.example.org"' -
mig nk-setup-conf-off configured auto 'TZ_NAME="UTC"' - 'KIOSK_URL=' 'TSX_SETUP_KIOSK=off'
# with a kiosk: a page URL
mig k-fresh unconfigured on - - -
mig k-panel-url configured on 'KIOSK_URL="https://ha.example.org/lovelace/0"' - -
mig k-keys-but-no-url unconfigured on "TZ_NAME=\"UTC\"
SSH_AUTHORIZED_KEY=\"$KEY\"
HA_URL=\"https://ha.example.org:8123\"" - -
mig k-url-only-in-etc-kiosk configured on - 'KIOSK_URL="https://ha.example.org"' -
mig k-url-only-in-defaults configured on - - 'KIOSK_URL="https://ha.example.org"'
mig k-etc-empties-defaults unconfigured on - 'KIOSK_URL=""' 'KIOSK_URL="https://ha.example.org"'
mig k-blank-panel-url unconfigured on 'KIOSK_URL="   "' - 'KIOSK_URL=""'
mig k-blank-panel-url-etc-url configured on 'KIOSK_URL="   "' 'KIOSK_URL=https://ha.example.org' -
mig k-hash-value configured on - 'KIOSK_URL=#x' -
mig k-commented-etc unconfigured on - '# KIOSK_URL="https://ha.example.org"' -
mig k-auto-defaults-no-url unconfigured auto 'TZ_NAME="UTC"' - 'KIOSK_URL='
mig k-auto-defaults-url configured auto - - 'KIOSK_URL="https://ha.example.org"'
mig k-setup-conf-on unconfigured auto 'TZ_NAME="UTC"' - - 'TSX_SETUP_KIOSK=on'
mig k-setup-conf-bad-is-auto configured auto 'TZ_NAME="UTC"' - - 'TSX_SETUP_KIOSK=maybe'

echo "== the migration: the stamp, a power cut, and no answer =="
mrun() {  # mrun DIR [VAR=value...]: tsx-setup-helper migrate on DIR (no kiosk)
	local d=$1; shift
	env TSX_SETUP_KIOSK=off TSX_CONF="$d/panel.conf" TSX_KIOSK_CONF="$d/kiosk.conf" TSX_SETUP_CONF="$d/setup.conf" \
		TSX_DEFAULTS_DIR="$d/defaults" TSX_CONFIG_BIN="$T/bin/tsx-config" PATH="$T/bin:$PATH" "$@" \
		busybox sh "$HELPER" migrate > "$d/migrate.log" 2>&1
}
d="$T/s1"; mkdir -p "$d"; echo 'TZ_NAME="UTC"' > "$d/panel.conf"; echo 2 > "$d/setup-v2"
mrun "$d"; [ $? = 0 ] && [ ! -e "$d/setup-done" ] && ok "with the stamp there is no migration (a configured panel.conf of the old rule stays unconfigured)" || bad "stamp: $(cat "$d/migrate.log")"
[ ! -s "$d/migrate.log" ] && ok "and nothing is logged" || bad "log with the stamp: $(cat "$d/migrate.log")"
d="$T/s2"; mkdir -p "$d"; echo 'TZ_NAME="UTC"' > "$d/panel.conf"; : > "$d/.setup-v2.tmp.4242"
mrun "$d"; [ $? = 0 ] && [ -e "$d/setup-done" ] && [ "$(cat "$d/setup-v2")" = 2 ] && ok "a torn temporary file of the stamp: the migration runs" || bad "torn stamp temp: $(cat "$d/migrate.log")"
ls -A "$d" | grep -q tmp && bad "the torn temporary file stays: $(ls -A "$d")" || ok "and the torn temporary file is gone"
d="$T/s3"; mkdir -p "$d"; : > "$d/.setup-done.tmp.4242"
mrun "$d"; [ $? = 0 ] && [ ! -e "$d/setup-done" ] && [ -e "$d/setup-v2" ] && ok "a torn temporary file of the marker on a fresh panel: unconfigured" || bad "torn marker temp: $(ls -A "$d")"
d="$T/s4"; mkdir -p "$d"; echo migrated > "$d/setup-done"
mrun "$d"; [ $? = 0 ] && [ "$(cat "$d/setup-done")" = migrated ] && [ -e "$d/setup-v2" ] && ok "a cut after the marker and before the stamp: the next run writes the stamp, the marker stays" || bad "marker without stamp: $(cat "$d/migrate.log")"
grep -q 'tsx_setup_write "\$TSX_SETUP_DONE_FILE"' "$HELPER" && awk '/tsx_setup_write "\$TSX_SETUP_DONE_FILE"/{m=NR} /tsx_setup_write "\$TSX_SETUP_V2_FILE"/{s=NR} END{exit !(m && s && m < s)}' "$HELPER" \
	&& ok "the helper writes the marker before the stamp" || bad "the order of the writes"
if [ "$ROOT" = 0 ]; then
	d="$T/s5"; mkdir -p "$d"; echo 'TZ_NAME="UTC"' > "$d/panel.conf"; chmod 000 "$d/panel.conf"
	mrun "$d"; rc=$?
	[ $rc != 0 ] && [ ! -e "$d/setup-done" ] && [ ! -e "$d/setup-v2" ] && ok "a panel.conf that cannot be read: no answer, nothing written (exit $rc)" || bad "unreadable panel.conf: rc $rc $(ls -A "$d")"
	grep -q 'cannot be read' "$d/migrate.log" && ok "the log says why" || bad "log: $(cat "$d/migrate.log")"
	chmod 600 "$d/panel.conf"
else
	echo "  (root: the unreadable panel.conf check is skipped)"
fi
d="$T/s6"; mkdir -p "$d/panel.conf"
mrun "$d"; [ $? != 0 ] && [ ! -e "$d/setup-v2" ] && [ ! -e "$d/setup-done" ] && ok "a panel.conf that is a folder: no answer, nothing written" || bad "folder panel.conf: $(ls -A "$d")"
printf '#!/bin/sh\necho "tsx-config: ERROR: broken" >&2\nexit 2\n' > "$T/bin/tsx-config-broken"; chmod +x "$T/bin/tsx-config-broken"
d="$T/s7"; mkdir -p "$d"; echo 'TZ_NAME="UTC"' > "$d/panel.conf"
mrun "$d" TSX_CONFIG_BIN="$T/bin/tsx-config-broken"; [ $? != 0 ] && [ ! -e "$d/setup-v2" ] && [ ! -e "$d/setup-done" ] && ok "a failed tsx-config show: no answer, nothing written" || bad "broken show: $(ls -A "$d")"
d="$T/s8"; mkdir -p "$d"; echo 'TZ_NAME="UTC"' > "$d/panel.conf"
mrun "$d" TSX_PYTHON_BIN=false; [ $? != 0 ] && [ ! -e "$d/setup-v2" ] && [ ! -e "$d/setup-done" ] && ok "python fails (exit 1): no answer, nothing written" || bad "python false: $(ls -A "$d")"
printf '#!/bin/sh\necho configured-ish\n' > "$T/bin/py-odd"; chmod +x "$T/bin/py-odd"
d="$T/s9"; mkdir -p "$d"; echo 'TZ_NAME="UTC"' > "$d/panel.conf"
mrun "$d" TSX_PYTHON_BIN="$T/bin/py-odd"; [ $? != 0 ] && [ ! -e "$d/setup-v2" ] && ok "an answer that is not configured or unconfigured: nothing written" || bad "odd answer: $(ls -A "$d")"
d="$T/s10"; mkdir -p "$d"
mrun "$d" TSX_BASE_LIB_DIR="$T/none" PYTHONPATH="$T/none"
[ $? = 0 ] && ok "python3 -I: the old rule finds tsx_conf next to it or in the checkout" || bad "tsx_conf not found: $(cat "$d/migrate.log")"
python3 -I "$OLDRULE" < /dev/null > "$T/o.out" 2>&1; [ "$(cat "$T/o.out")" = configured ] || [ "$(cat "$T/o.out")" = unconfigured ] \
	&& ok "setup_old_rule.py answers on stdout ($(cat "$T/o.out"))" || bad "setup_old_rule.py: $(cat "$T/o.out")"

# ---- 4. the init script ------------------------------------------------------------
echo "== the init script of tsx-setup-helper =="
INIT="$HERE/setup/etc/init.d/tsx-setup-helper"
sed -n '/^start_pre()/,/^}/p' "$INIT" | grep -q '/usr/local/sbin/tsx-setup-helper migrate' && ok "start_pre runs tsx-setup-helper migrate" || bad "start_pre has no migrate"
sed -n '/^start_pre()/,/^}/p' "$INIT" | grep -q 'return 0' && ok "a failed migration does not stop the start" || bad "start_pre can fail"
grep -q 'after tsx-config' "$INIT" && grep -q 'before tsx-setupd' "$INIT" && ok "after tsx-config (the seed is promoted), before tsx-setupd (the reader)" || bad "the order of the init script"
grep -q 'after .*tsx-setup-helper' "$HERE/setup/etc/init.d/tsx-setupd" && ok "tsx-setupd starts after tsx-setup-helper" || bad "tsx-setupd order"

# ---- 5. tsx-setupd: the answer of the helper ----------------------------------------
echo "== tsx-setupd: only \"done\" and \"open\" are answers; anything else is configured =="
answer() {  # answer OK TEXT -> True/False (is_configured)
	env TSX_SETUP_KIOSK=off TSX_SETUP_CONF="$T/none.conf" TSX_RUN_DIR="$T/ic-run" TSX_KIOSK_CONF="$T/none.conf" \
		TSX_SETUP_PLUGIN_DIR="$T/none" TSX_SETUP_NO_ZEROCONF=1 python3 -c 'import sys, importlib.machinery as m
d = m.SourceFileLoader("setupd", sys.argv[1]).load_module()
calls = []
def fake(line, timeout=None):
    calls.append(line)
    return (sys.argv[2] == "1", sys.argv[3])
d.helper_call = fake
v = d.is_configured()
assert calls == ["setup-state"], calls
print(v)' "$SETUPD" "$1" "$2" 2>/dev/null
}
[ "$(answer 1 done)" = True ] && ok "done: configured" || bad "done"
[ "$(answer 1 open)" = False ] && ok "open: not configured" || bad "open"
[ "$(answer 0 'tsx-setup-helper not listening')" = True ] && ok "no helper: configured" || bad "no helper"
[ "$(answer 0 'unknown command')" = True ] && ok "an older helper (unknown command): configured" || bad "older helper"
[ "$(answer 0 'setup-state: the setup state of an earlier release is not moved over')" = True ] && ok "a failed migration: configured" || bad "failed migration"
[ "$(answer 1 'open please')" = True ] && ok "another text: configured" || bad "other text"
! grep -n 'is_configured_from\|def has_url' "$SETUPD" | grep -v '^[0-9]*:def has_url' | grep -q . && ok "tsx-setupd has no copy of the old rule (has_url stays for the check of a save)" || bad "tsx-setupd still uses the old rule"

# ---- 6. the daemons: the installer contract, a fresh panel, an old panel ------------------
echo "== the daemons: the RAM installer of uc-pxx, a fresh panel, an old configured panel =="
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("0.0.0.0", 0)); print(s.getsockname()[1]); s.close()'; }
LANIP=$(python3 -c "
import socket
try:
	s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('192.0.2.1', 80)); print(s.getsockname()[0])
except Exception:
	print('')" 2>/dev/null)
[ "$LANIP" != 127.0.0.1 ] || LANIP=
cat > "$T/client.py" <<'PYEOF'
import http.client, json, sys, time
method, path, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
data = sys.argv[4] if len(sys.argv) > 4 else None
for _ in range(20):
    try:
        h = {}
        if method == "POST":
            c0 = http.client.HTTPConnection("127.0.0.1", port, timeout=120)
            c0.request("GET", "/setup/api/state")
            h["X-TSX-CSRF"] = json.loads(c0.getresponse().read()).get("csrf") or ""
            h["Content-Type"] = "application/json"
            c0.close()
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=120)
        c.request(method, path, body=data.encode() if data else None, headers=h)
        r = c.getresponse()
        print(r.status)
        print(r.read().decode(errors="replace"))
        sys.exit(0)
    except (ConnectionRefusedError, ConnectionResetError):
        time.sleep(0.3)
print(0); print("{}")
PYEOF
jget() { python3 -c 'import json, sys
v = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    v = v.get(k) if isinstance(v, dict) else None
print("" if v is None else v)' "$1"; }
wait_for() { local n=$(($1 * 5)); shift; while [ "$n" -gt 0 ]; do "$@" && return 0; n=$((n - 1)); sleep 0.2; done; return 1; }
listens_on() { ss -ltn 2>/dev/null | grep -q "$1:$2\b"; }
lan_on() { listens_on 0.0.0.0 "$1"; }
lan_off() { listens_on 127.0.0.1 "$1" && ! listens_on 0.0.0.0 "$1"; }
has_file() { [ -e "$1" ]; }
no_file() { [ ! -e "$1" ]; }
# boot DIR: the boot of a panel with /data in DIR: tsx-config apply (the
# service tsx-config), then tsx-setup-helper (its start_pre: migrate, then
# the daemon) and tsx-setupd, with no kiosk (BOOT_KIOSK=on: with the kiosk,
# as the kiosk profile of uc-pxx)
boot() {
	local d=$1; mkdir -p "$d/run/tsx" "$d/state" "$d/prefix/etc" "$d/zoneinfo"
	[ -e "$d/prefix/etc/shadow" ] || echo 'root:!:19000:0:99999:7:::' > "$d/prefix/etc/shadow"
	PORT=$(free_port)
	printf 'TSX_SETUP_PORT=%s\nTSX_SETUP_LAN=on\nTSX_SETUP_HA_LOGIN=off\nTSX_SETUP_WINDOW=900\n' "$PORT" > "$d/setup.conf"
	local e=(TSX_CONF="$d/panel.conf" TSX_RUN="$d/run" TSX_RUN_DIR="$d/run/tsx" TSX_APPLY_ALLOW_NONROOT=1
		TSX_APPLY_PREFIX="$d/prefix" TSX_STATE_DIR="$d/tsx-state" TSX_SETUP_KIOSK="${BOOT_KIOSK:-off}" TSX_SETUP_CONF="$d/setup.conf"
		TSX_KIOSK_CONF="$d/kiosk.conf" TSX_DEFAULTS_DIR="$d/defaults" TSX_CONFIG_BIN="$T/bin/tsx-config"
		TSX_RCSERVICE_BIN="$T/bin/rc-service" TSX_SETUP_STATE_DIR="$d/state")
	env "${e[@]}" busybox sh "$TSXCONFIG" apply > "$d/apply.log" 2>&1
	env "${e[@]}" PATH="$T/bin:$PATH" busybox sh "$HELPER" migrate > "$d/helper.log" 2>&1
	env "${e[@]}" PATH="$T/bin:$PATH" busybox sh "$HELPER" >> "$d/helper.log" 2>&1 &
	PIDS="$PIDS $!"
	wait_for 10 grep -q "listening on" "$d/helper.log" || bad "$d: helper did not start: $(cat "$d/helper.log")"
	env "${e[@]}" TSX_ZONEINFO_DIR="$d/zoneinfo" TSX_SETUP_NO_ZEROCONF=1 TSX_SETUP_PLUGIN_DIR="$T/none" \
		python3 "$SETUPD" > "$d/setupd.log" 2>&1 &
	SETUPD_PID=$!; PIDS="$PIDS $!"
	wait_for 10 grep -q "listening on" "$d/setupd.log" || bad "$d: tsx-setupd did not start: $(cat "$d/setupd.log")"
}
call() { python3 "$T/client.py" "$1" "$2" "$PORT" "${3:-}"; }

# 6a. the contract of uc-pxx-inst: a fresh mainline slot
I="$T/inst"; mkdir -p "$I"
printf 'SSH_AUTHORIZED_KEY="%s"\n' "$KEY" > "$I/panel.conf"; chmod 600 "$I/panel.conf"
printf '2\n' > "$I/setup-v2"; chmod 644 "$I/setup-v2"
[ "$(TSX_CONF="$I/panel.conf" busybox sh "$TSXCONFIG" get SSH_AUTHORIZED_KEY)" = "$KEY" ] && ok "installer: the line is in the store format of tsx-config" || bad "installer: tsx-config get"
boot "$I"
grep -qxF "$KEY" "$I/prefix/root/.ssh/authorized_keys" 2>/dev/null && ok "installer: apply at boot gives root the key (authorized_keys)" || bad "installer: no key for root: $(cat "$I/apply.log")"
[ "$(stat -c %a "$I/prefix/root/.ssh/authorized_keys" 2>/dev/null)" = 600 ] && ok "installer: authorized_keys has mode 600" || bad "installer: authorized_keys mode"
[ ! -e "$I/setup-done" ] && ok "installer: no marker after the boot (the stamp stops the migration; a key never configures)" || bad "installer: the marker was written: $(cat "$I/helper.log")"
grep -q 'setup-migrate' "$I/helper.log" && bad "installer: the migration ran: $(cat "$I/helper.log")" || ok "installer: the migration did not run"
[ "$(cat "$I/setup-v2")" = 2 ] && [ "$(stat -c %a "$I/panel.conf")" = 600 ] && ok "installer: the stamp and panel.conf are as the installer wrote them" || bad "installer: files changed"
body=$(call GET /setup/api/state | sed -n '2,$p')
[ "$(jget configured <<<"$body")" = False ] && ok "installer: the state API says not configured" || bad "installer: state: $body"
printf '%s' "$(jget pairing_code <<<"$body")" | grep -Eq '^[0-9]{6}$' && ok "installer: the pairing code works (loopback gets it)" || bad "installer: no pairing code: $body"
[ "$(jget lan_allowed <<<"$body")" = True ] && ok "installer: the LAN window is open" || bad "installer: lan_allowed: $body"
wait_for 10 lan_on "$PORT" && ok "installer: tsx-setupd listens on 0.0.0.0" || bad "installer: not on the LAN: $(ss -ltn | grep ":$PORT")"
wait_for 10 has_file "$I/state/screen.json" && ok "installer: screen.json (the setup bar of the panel app) is there" || bad "installer: no screen.json"
if [ -n "$LANIP" ]; then
	r=$(python3 -c 'import http.client, sys
c = http.client.HTTPConnection(sys.argv[1], int(sys.argv[2]), timeout=5, source_address=(sys.argv[1], 0))
c.request("GET", "/setup/api/state"); print(c.getresponse().status)' "$LANIP" "$PORT" 2>/dev/null)
	[ "$r" = 200 ] && ok "installer: a LAN client reaches the page" || bad "installer: LAN: $r"
fi
echo "== a save of the setup page writes the marker =="
out=$(call POST /setup/api/submit '{"revision": null, "fields": {}}')
[ "$(echo "$out" | sed -n 1p)" = 200 ] && ok "save: a save with no change is accepted" || bad "save: $out"
[ "$(cat "$I/setup-done" 2>/dev/null)" = done ] && [ "$(stat -c %a "$I/setup-done")" = 644 ] && ok "save: the marker is written (done, mode 644)" || bad "save: no marker: $(ls -A "$I")"
grep -q 'tsx-setup-helper: setup-done' "$I/helper.log" && ok "save: through the helper command setup-done" || bad "save: helper log"
body=$(call GET /setup/api/state | sed -n '2,$p')
[ "$(jget configured <<<"$body")" = True ] && ok "save: the state API says configured at once" || bad "save: state $body"
wait_for 15 no_file "$I/state/screen.json" && ok "save: screen.json is gone" || bad "save: screen.json stays"
wait_for 15 lan_off "$PORT" && ok "save: the listener is on loopback only" || bad "save: listeners $(ss -ltn | grep ":$PORT")"
n=$(grep -c 'tsx-setup-helper: setup-done' "$I/helper.log")
out=$(call POST /setup/api/submit '{"revision": null, "fields": {}}')
[ "$(echo "$out" | sed -n 1p)" = 200 ] && [ "$(grep -c 'tsx-setup-helper: setup-done' "$I/helper.log")" = "$n" ] && ok "save on a configured panel: no second setup-done" || bad "second save: $out"
grep -q 'setup-state' "$I/helper.log" && bad "the helper logs setup-state (asked every 4 s)" || ok "setup-state writes no log line"
for p in $PIDS; do kill "$p" 2>/dev/null; done; PIDS=

# 6a'. the same files on a panel with the kiosk, whose image has a page URL
K="$T/inst-k"; mkdir -p "$K"
printf 'SSH_AUTHORIZED_KEY="%s"\n' "$KEY" > "$K/panel.conf"; chmod 600 "$K/panel.conf"
printf '2\n' > "$K/setup-v2"; chmod 644 "$K/setup-v2"
printf 'KIOSK_URL="https://ha.example.org/lovelace/0"\n' > "$K/kiosk.conf"
BOOT_KIOSK=on boot "$K"
body=$(call GET /setup/api/state | sed -n '2,$p')
[ "$(jget kiosk <<<"$body")" = True ] && [ "$(jget configured <<<"$body")" = False ] && ok "installer, kiosk: a page URL in kiosk.conf does not make the panel configured" || bad "installer, kiosk: $body"
wait_for 10 lan_on "$PORT" && ok "installer, kiosk: the LAN window is open" || bad "installer, kiosk: LAN"
out=$(call POST /setup/api/submit '{"revision": null, "fields": {}}')
[ "$(echo "$out" | sed -n 1p)" = 200 ] && [ -e "$K/setup-done" ] && wait_for 15 lan_off "$PORT" && ok "installer, kiosk: the first save writes the marker and closes the window" || bad "installer, kiosk save: $out"
for p in $PIDS; do kill "$p" 2>/dev/null; done; PIDS=

# 6b. a fresh panel: no panel.conf, no stamp
Z="$T/fresh"; mkdir -p "$Z"
boot "$Z"
[ "$(cat "$Z/setup-v2" 2>/dev/null)" = 2 ] && [ ! -e "$Z/setup-done" ] && ok "fresh: the migration writes the stamp and no marker" || bad "fresh: $(ls -A "$Z") $(cat "$Z/helper.log")"
body=$(call GET /setup/api/state | sed -n '2,$p')
[ "$(jget configured <<<"$body")" = False ] && wait_for 10 lan_on "$PORT" && ok "fresh: not configured, the LAN window is open" || bad "fresh: $body"
for p in $PIDS; do kill "$p" 2>/dev/null; done; PIDS=

# 6c. a panel of an earlier release: a configured panel.conf, no stamp
O="$T/oldpanel"; mkdir -p "$O"
printf 'TZ_NAME="UTC"\nUPDATE_MODE="manual"\n' > "$O/panel.conf"; chmod 600 "$O/panel.conf"
boot "$O"
[ "$(cat "$O/setup-done" 2>/dev/null)" = migrated ] && [ -e "$O/setup-v2" ] && ok "old panel: the migration writes the marker, then the stamp" || bad "old panel: $(ls -A "$O") $(cat "$O/helper.log")"
body=$(call GET /setup/api/state | sed -n '2,$p')
[ "$(jget configured <<<"$body")" = True ] && wait_for 10 lan_off "$PORT" && ok "old panel: configured, loopback only" || bad "old panel: $body"
[ ! -e "$O/state/screen.json" ] && ok "old panel: no screen.json" || bad "old panel: screen.json"
for p in $PIDS; do kill "$p" 2>/dev/null; done; PIDS=

# 6d. an update with no restart of the helper: the stamp is missing when tsx-setupd asks
L="$T/lazy"; mkdir -p "$L/run/tsx" "$L/state"
printf 'TZ_NAME="UTC"\n' > "$L/panel.conf"
PORT=$(free_port)
printf 'TSX_SETUP_PORT=%s\nTSX_SETUP_LAN=on\nTSX_SETUP_HA_LOGIN=off\n' "$PORT" > "$L/setup.conf"
le=(TSX_CONF="$L/panel.conf" TSX_RUN="$L/run" TSX_RUN_DIR="$L/run/tsx" TSX_APPLY_ALLOW_NONROOT=1 TSX_SETUP_KIOSK=off
	TSX_SETUP_CONF="$L/setup.conf" TSX_KIOSK_CONF="$L/kiosk.conf" TSX_DEFAULTS_DIR="$L/defaults"
	TSX_CONFIG_BIN="$T/bin/tsx-config" TSX_SETUP_STATE_DIR="$L/state")
env "${le[@]}" PATH="$T/bin:$PATH" busybox sh "$HELPER" > "$L/helper.log" 2>&1 &
PIDS="$PIDS $!"
wait_for 10 grep -q "listening on" "$L/helper.log"
printf 'setup-state\n' > "$L/run/tsx/setup-helper"; r=$(timeout 30 head -1 "$L/run/tsx/setup-helper.resp")
[ "$r" = "ok done" ] && [ -e "$L/setup-done" ] && [ -e "$L/setup-v2" ] && ok "no stamp at the first setup-state: the helper migrates first, then answers (ok done)" || bad "lazy: '$r' $(cat "$L/helper.log")"
rm -f "$L/setup-v2" "$L/setup-done"; chmod 000 "$L/panel.conf" 2>/dev/null
if [ "$ROOT" = 0 ]; then
	printf 'setup-state\n' > "$L/run/tsx/setup-helper"; r=$(timeout 30 head -1 "$L/run/tsx/setup-helper.resp")
	case "$r" in err*) ok "a migration that fails: setup-state answers err (tsx-setupd: configured): $r";; *) bad "failed migration answered: $r";; esac
	chmod 600 "$L/panel.conf"
	printf 'setup-state\n' > "$L/run/tsx/setup-helper"; r=$(timeout 30 head -1 "$L/run/tsx/setup-helper.resp")
	case "$r" in err*) ok "within 60 s the helper does not run the failed migration again: $r";; *) bad "retry at once: $r";; esac
	[ "$(grep -c 'cannot be read' "$L/helper.log")" = 1 ] && ok "one migration in that time" || bad "migrations: $(grep -c 'cannot be read' "$L/helper.log")"
fi
r=$(printf 'setup-state now\n' > "$L/run/tsx/setup-helper"; timeout 10 head -1 "$L/run/tsx/setup-helper.resp")
case "$r" in err*) ok "setup-state with an argument is refused";; *) bad "setup-state now: $r";; esac
r=$(printf 'setup-done x\n' > "$L/run/tsx/setup-helper"; timeout 10 head -1 "$L/run/tsx/setup-helper.resp")
case "$r" in err*) ok "setup-done with an argument is refused";; *) bad "setup-done x: $r";; esac

echo "== $N ok, $F failed =="
[ "$F" = 0 ]
