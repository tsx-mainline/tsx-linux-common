# serial.sh: the serial console of the board.
#   . /usr/local/lib/tsx/serial.sh
#   tsx_serial_say "text"           write one line to the kernel log and to
#                                   the serial console
#   tsx_serial_allow_root [FILE]    make the serial console a line of FILE
#                                   (default /etc/securetty), so root can log
#                                   in there. /etc/init.d/tsx-config runs it
#                                   at each start.
# The serial console is TSX_SERIAL_CONSOLE of the board file (for example
# ttyS0). Without it, the function uses the serial consoles that
# the kernel lists in /proc/consoles. Test hooks: TSX_PROC_CONSOLES,
# TSX_SECURETTY (the securetty file that tsx_serial_allow_root changes).
tsx_serial_say() {
	echo "$1" > /dev/kmsg 2>/dev/null
	_ss_list=${TSX_SERIAL_CONSOLE:-}
	[ -n "$_ss_list" ] || _ss_list=$(awk '$1 ~ /^tty[A-Z]/ { print $1 }' "${TSX_PROC_CONSOLES:-/proc/consoles}" 2>/dev/null)
	for _ss_c in $_ss_list; do
		[ -c "/dev/$_ss_c" ] && echo "$1" > "/dev/$_ss_c" 2>/dev/null
	done
	return 0
}

# tsx_serial_allow_root [FILE]: add each name of TSX_SERIAL_CONSOLE to the
# securetty FILE when the file does not list it. The package ships the list
# with no board console. The function does nothing when the board names no
# console, and when FILE does not exist (without the file, root can log in on
# every tty). It adds no duplicate line. It returns 1 when a name is not a
# device name or when a write fails.
tsx_serial_allow_root() {
	_sa_f=${1:-${TSX_SECURETTY:-/etc/securetty}}
	_sa_rc=0
	[ -f "$_sa_f" ] || return 0
	for _sa_c in ${TSX_SERIAL_CONSOLE:-}; do
		case $_sa_c in *[!A-Za-z0-9_.-]*) _sa_rc=1; continue;; esac
		grep -qxF "$_sa_c" "$_sa_f" 2>/dev/null && continue
		# a file with no final newline gets one first
		if [ -s "$_sa_f" ] && [ -n "$(tail -c 1 "$_sa_f")" ]; then echo >> "$_sa_f" || _sa_rc=1; fi
		echo "$_sa_c" >> "$_sa_f" || _sa_rc=1
	done
	return $_sa_rc
}
