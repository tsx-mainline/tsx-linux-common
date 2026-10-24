# presence-kind.sh: the one rule that maps PRESENCE of /run/tsx/hw.conf to a
# sensor kind. Source this file. The Python version is tsx_presence.py in the
# same folder. Keep both the same.
#
#   presence_kind [-q] [RAW]   print the kind: no, tof or pir
#
# RAW is the value of PRESENCE in hw.conf:
#   no            no sensor
#   tof           time-of-flight sensor: presence and distance
#   pir           motion sensor: presence only
#   yes           tof (yes is the old name)
#   empty         no, with no warning (a missing key means no sensor)
#   other         no, with a warning on stderr (-q turns the warning off)
#
# This file is the authority. The small copies in tsx-config, tsx-mqtt,
# tsx-setupd and the ESPHome shim (hw.py) keep the same rule, with no warning.
presence_kind() {
	_pk_q=0
	if [ "${1:-}" = -q ]; then _pk_q=1; shift; fi
	case "${1:-}" in
	no|"") echo no;;
	pir) echo pir;;
	tof|yes) echo tof;;
	*)
		[ "$_pk_q" = 1 ] || echo "WARNING: PRESENCE=$1 in hw.conf is not no, tof, pir or yes. Treated as no." >&2
		echo no;;
	esac
}
