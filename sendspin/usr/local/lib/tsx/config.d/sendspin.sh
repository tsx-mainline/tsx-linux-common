# sendspin.sh: the plugin of tsx-config for the Sendspin player (package
# tsx-sendspin, docs/sendspin.md).
#
# Key:
#   SENDSPIN  on or off. apply with "on" puts dbus, avahi-daemon and
#             tsx-sendspin into the default runlevel and starts them. apply
#             with "off" stops tsx-sendspin and takes it out of the runlevel
#             (dbus and avahi-daemon stay, other services can use them).
#             Not set: apply does not change the runlevel. An image or the
#             audio tool of a board can then enable the player.
# A panel with no sound card (TSX_SOUND_CARD of the board file is empty)
# accepts SENDSPIN=on with a warning, and apply treats it as off.
# Inside an OpenRC service (the boot apply of the service tsx-config, where
# RC_SVCNAME is set), apply only changes the runlevel. A start there would
# wait for tsx-config itself. The default runlevel starts the player later.
# Test hooks: TSX_RC_UPDATE_BIN, TSX_RC_SERVICE_BIN, TSX_RUNLEVEL_DIR.

CFG_SENDSPIN_KEYS="SENDSPIN"

cfg_sendspin_valid() {
	case "$1" in
	SENDSPIN) case "$2" in on|off) return 0;; esac; return 1;;
	esac
	return 1
}

cfg_sendspin_missing() {
	[ -z "${TSX_SOUND_CARD:-}" ] || return 1
	echo "this panel has no sound card"
}

# _ss_enabled: tsx-sendspin is in the default runlevel
_ss_enabled() { [ -e "${TSX_RUNLEVEL_DIR:-/etc/runlevels/default}/tsx-sendspin" ]; }

cfg_sendspin_apply() {
	_ss_v=$(cfg_get SENDSPIN) || _ss_v=
	if [ "$_ss_v" = on ] && hw_missing SENDSPIN >/dev/null; then
		hw_warn SENDSPIN on
		_ss_v=off
	fi
	_ss_rcu=${TSX_RC_UPDATE_BIN:-rc-update}
	_ss_rcs=${TSX_RC_SERVICE_BIN:-rc-service}
	command -v "$_ss_rcu" >/dev/null 2>&1 || return 0
	case "$_ss_v" in
	on)
		_ss_was=no
		_ss_enabled && _ss_was=yes
		for _ss_s in dbus avahi-daemon tsx-sendspin; do
			"$_ss_rcu" add "$_ss_s" default >/dev/null 2>&1 || true
		done
		[ "$_ss_was" = no ] && log "SENDSPIN=on: tsx-sendspin added to the default runlevel"
		if [ -z "${RC_SVCNAME:-}" ]; then
			for _ss_s in dbus avahi-daemon tsx-sendspin; do
				"$_ss_rcs" -q "$_ss_s" start >/dev/null 2>&1 || true
			done
		fi;;
	off)
		if _ss_enabled; then
			[ -n "${RC_SVCNAME:-}" ] || "$_ss_rcs" -q tsx-sendspin stop >/dev/null 2>&1 || true
			"$_ss_rcu" del tsx-sendspin default >/dev/null 2>&1 || true
			log "SENDSPIN=off: tsx-sendspin stopped and taken out of the default runlevel"
		fi;;
	esac
	return 0
}
