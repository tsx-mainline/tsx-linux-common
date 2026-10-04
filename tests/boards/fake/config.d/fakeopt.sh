# fakeopt.sh: a plugin of tsx-config for the made-up board "fake"
# (docs/layout.md "Plugin folders"). No real part is behind it. The tests
# of the config.d loader use it in place of the plugin of a real board.
#
# Keys: FAKEOPT (off | low | high) and FAKEOPT_TOKEN (a secret, 8 or more
# letters and digits). The part is missing when hw.conf says FAKEOPT=no.
# Apply writes $RUN/fakeopt.conf and reports the mode as the signature.

CFG_FAKEOPT_KEYS="FAKEOPT FAKEOPT_TOKEN"
CFG_FAKEOPT_SECRET_KEYS="FAKEOPT_TOKEN"

cfg_fakeopt_valid() {
	case "$1" in
	FAKEOPT) case "$2" in off|low|high) return 0;; esac; return 1;;
	FAKEOPT_TOKEN) printf '%s' "$2" | grep -Eq '^[A-Za-z0-9]{8,}$';;
	*) return 1;;
	esac
}

cfg_fakeopt_missing() {
	[ "$(hw_get FAKEOPT)" = no ] || return 1
	echo "this panel has no fake option ($(hw_get REASON))"
}

cfg_fakeopt_apply() {
	_fo_mode=$(cfg_get FAKEOPT) || _fo_mode=off
	if cfg_fakeopt_missing FAKEOPT >/dev/null; then hw_warn FAKEOPT "$_fo_mode"; _fo_mode=off; fi
	case "$_fo_mode" in low|high) ;; *) _fo_mode=off;; esac
	printf 'FAKEOPT="%s"\n' "$_fo_mode" | write_override "$RUN/fakeopt.conf" 644
	CFG_FAKEOPT_SIG=$_fo_mode
}
