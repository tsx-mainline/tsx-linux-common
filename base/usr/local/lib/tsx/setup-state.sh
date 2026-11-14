# setup-state.sh: the one rule that says if the setup of the panel is done
# (the panel is "configured").
#   . /usr/local/lib/tsx/setup-state.sh
#
# The panel is configured when the marker file /data/tsx/setup-done exists.
# Nothing else makes a panel configured: no key of panel.conf (also not
# SSH_AUTHORIZED_KEY, KIOSK_URL or HA_URL) and no page URL. While the panel is
# not configured, the setup page has its pairing code, its LAN window and (on
# a native screen) its setup bar. Only these write the marker:
#   - a successful save of the setup page (tsx-setupd asks tsx-setup-helper
#     "setup-done", which runs `tsx-config setup-done`)
#   - `tsx-config setup-done`, run by root
#   - once, the migration of tsx-setup-helper (see the stamp below), for a
#     panel that the rule of the earlier releases called configured
#
# The stamp /data/tsx/setup-v2 says that this rule holds for this /data: the
# migration has run, or an installer made a new /data with the stamp. While
# the stamp is missing, tsx-setup-helper runs the migration before it answers
# "setup-state", and it gives no answer when the migration fails. tsx-setupd
# then acts as on a configured panel.
#
# Both files: owner root, mode 644, one line, written with tsx_setup_write
# (a temporary file in the same folder, fsync, rename, fsync of the folder).
# The marker comes first, the stamp after it. A power cut can leave a
# temporary file: it counts for nothing, and the next write removes it.
#
#   tsx_setup_done         exit 0 when the panel is configured (also when it
#                          is not known whether the marker exists)
#   tsx_setup_stamped      exit 0 when the stamp exists, 1 when it does not,
#                          2 when that is not known
#   tsx_setup_entry FILE   the same three answers for any FILE
#   tsx_setup_write FILE LINE
#                          write LINE to FILE as above. Exit 1 on an error
#                          (then FILE is as it was).
#
# The files are next to panel.conf (TSX_CONF, default /data/tsx/panel.conf).
# TSX_SETUP_DONE_FILE and TSX_SETUP_V2_FILE replace the paths (tests).
# It uses busybox ash and plain POSIX sh only.

_tss_conf=${TSX_CONF:-/data/tsx/panel.conf}
case $_tss_conf in */*) _tss_dir=${_tss_conf%/*};; *) _tss_dir=.;; esac
[ -n "$_tss_dir" ] || _tss_dir=/
TSX_SETUP_DONE_FILE=${TSX_SETUP_DONE_FILE:-$_tss_dir/setup-done}
TSX_SETUP_V2_FILE=${TSX_SETUP_V2_FILE:-$_tss_dir/setup-v2}

# tsx_setup_entry FILE: exit 0 when the folder entry FILE exists (also a
# link), 1 when it does not exist, 2 when that is not known. "Does not exist"
# needs a folder that lists and has no such name (or a missing folder whose
# parent lists and has no such name). A stat error that is not "no such
# file" (EIO, ELOOP, EACCES ...), or a folder that cannot be listed, is 2.
tsx_setup_entry() {
	[ -e "$1" ] || [ -L "$1" ] && return 0
	_tse_d=${1%/*}; [ "$_tse_d" != "$1" ] || _tse_d=.
	[ -n "$_tse_d" ] || _tse_d=/
	if [ -d "$_tse_d" ]; then
		_tse_l=$(ls -A "$_tse_d" 2>/dev/null) || return 2
		# a name in the list that stat does not see: an error of the file system
		printf '%s\n' "$_tse_l" | grep -qxF -- "${1##*/}" && return 2
		return 1
	fi
	[ -e "$_tse_d" ] || [ -L "$_tse_d" ] && return 2
	_tse_p=${_tse_d%/*}; [ "$_tse_p" != "$_tse_d" ] || _tse_p=.
	[ -n "$_tse_p" ] || _tse_p=/
	_tse_l=$(ls -A "$_tse_p" 2>/dev/null) || return 2
	printf '%s\n' "$_tse_l" | grep -qxF -- "${_tse_d##*/}" && return 2
	return 1
}

# Not known counts as configured: the safe answer.
tsx_setup_done() { tsx_setup_entry "$TSX_SETUP_DONE_FILE" || [ $? = 2 ]; }
# 0 = the stamp exists, 1 = it does not, 2 = not known (a caller gives no answer)
tsx_setup_stamped() { tsx_setup_entry "$TSX_SETUP_V2_FILE"; }

tsx_setup_write() {
	_tsw_f=$1 _tsw_line=$2
	_tsw_d=${_tsw_f%/*}; [ "$_tsw_d" != "$_tsw_f" ] || _tsw_d=.
	_tsw_b=${_tsw_f##*/}
	if [ ! -d "$_tsw_d" ]; then
		# a new folder for panel.conf: the mode that tsx-config gives it
		mkdir -p "$_tsw_d" || return 1
		chmod 700 "$_tsw_d" 2>/dev/null || true
	fi
	# a temporary file of an earlier write that a power cut stopped
	for _tsw_o in "$_tsw_d/.$_tsw_b.tmp."*; do
		[ -e "$_tsw_o" ] || [ -L "$_tsw_o" ] || continue
		rm -f "$_tsw_o"
	done
	_tsw_t="$_tsw_d/.$_tsw_b.tmp.$$"
	if ! { (umask 022; printf '%s\n' "$_tsw_line" > "$_tsw_t") && chmod 644 "$_tsw_t" \
		&& { sync "$_tsw_t" 2>/dev/null || sync; } && mv -f "$_tsw_t" "$_tsw_f"; }; then
		rm -f "$_tsw_t"
		return 1
	fi
	# the new folder entry (sync FILE is an fsync; a sync with no FILE is the
	# fallback of an older sync)
	sync "$_tsw_d" 2>/dev/null || sync
	return 0
}
