# conf.sh: read and write the settings files that have a defaults layer.
#   . /usr/local/lib/tsx/conf.sh
#   tsx_conf_load NAME USER [BOARD [RUN]]
#                         source the layers of NAME in order. A later layer
#                         wins: the package defaults, BOARD, USER, RUN.
#   tsx_conf_get NAME KEY USER [BOARD [RUN]]
#                         print the last value of KEY in the layers, as text:
#                         no quotes, no comment. Nothing runs. Use it where a
#                         program must not source the file.
#   tsx_conf_defaults NAME   print the path of the defaults file of NAME
#   tsx_conf_set USER KEY VALUE
#                         set KEY=VALUE in the user file USER. It creates the
#                         file when it is missing, and appends a key that
#                         is not there yet. It never copies the defaults.
# NAME is the basename of the file, for example kiosk.conf. A file that is
# missing is not an error. The defaults layer is TSX_DEFAULTS_DIR (default
# /usr/local/share/tsx/defaults). Package updates replace the files there. The
# user file in /etc holds only the keys that the user changed.

tsx_conf_defaults() {
	echo "${TSX_DEFAULTS_DIR:-/usr/local/share/tsx/defaults}/$1"
}

tsx_conf_load() {
	_tc_def=$(tsx_conf_defaults "$1")
	for _tc_f in "$_tc_def" "${3:-}" "$2" "${4:-}"; do
		[ -n "$_tc_f" ] && [ -r "$_tc_f" ] || continue
		case $_tc_f in */*) . "$_tc_f";; *) . "./$_tc_f";; esac
	done
	return 0
}

tsx_conf_get() {
	for _tg_f in "$(tsx_conf_defaults "$1")" "${4:-}" "$3" "${5:-}"; do
		[ -n "$_tg_f" ] && [ -r "$_tg_f" ] && cat "$_tg_f"
	done 2>/dev/null | sed -n "s/^$2=//p" | tail -n 1 | sed "s/[[:space:]]*#.*//; s/^[\"']//; s/[\"']\$//"
	return 0
}

tsx_conf_set() {
	_ts_file=$1 _ts_key=$2 _ts_val=$3
	_ts_tmp="$_ts_file.tmp.$$"
	if [ -e "$_ts_file" ]; then
		_ts_k=$_ts_key _ts_v=$_ts_val awk '
			BEGIN { k = ENVIRON["_ts_k"]; v = ENVIRON["_ts_v"] }
			index($0, k "=") == 1 { if (!done) print k "=" v; done = 1; next }
			{ print }
			END { if (!done) print k "=" v }' "$_ts_file" > "$_ts_tmp" || { rm -f "$_ts_tmp"; return 1; }
		chmod "$(stat -c %a "$_ts_file" 2>/dev/null || echo 644)" "$_ts_tmp" 2>/dev/null
	else
		printf '%s=%s\n' "$_ts_key" "$_ts_val" > "$_ts_tmp" || return 1
		chmod 644 "$_ts_tmp"
	fi
	mv "$_ts_tmp" "$_ts_file"
}
