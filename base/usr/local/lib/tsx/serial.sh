# serial.sh: write one line to the kernel log and to the serial console.
#   . /usr/local/lib/tsx/serial.sh
#   tsx_serial_say "text"
# The serial console is TSX_SERIAL_CONSOLE of the board file (for example
# ttyAML0). Without it, the function uses the serial consoles that
# the kernel lists in /proc/consoles. Test hook: TSX_PROC_CONSOLES.
tsx_serial_say() {
	echo "$1" > /dev/kmsg 2>/dev/null
	_ss_list=${TSX_SERIAL_CONSOLE:-}
	[ -n "$_ss_list" ] || _ss_list=$(awk '$1 ~ /^tty[A-Z]/ { print $1 }' "${TSX_PROC_CONSOLES:-/proc/consoles}" 2>/dev/null)
	for _ss_c in $_ss_list; do
		[ -c "/dev/$_ss_c" ] && echo "$1" > "/dev/$_ss_c" 2>/dev/null
	done
	return 0
}
