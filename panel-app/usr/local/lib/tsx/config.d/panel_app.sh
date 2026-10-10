# panel_app.sh: the plugin of tsx-config for the screen of the panel app
# (docs/layout.md "Plugin folders", docs/panel-app.md "Screen").
#
# Keys:
#   DIM_TIMEOUT  seconds with no touch and no key before the screen dims,
#                0 = never. Apply writes it to $RUN/dim-timeout.
#   DIM_LEVEL    the backlight level of the dim screen, 1 to 100 (percent of
#                the brightness slider). Apply writes it to $RUN/dim-level.
# BLANK_TIMEOUT (the time before the screen goes off) is a key of tsx-config
# itself: apply writes $RUN/blank-timeout. The panel app reads the three
# files every 5 s. A key that is not set removes its file, and the app uses
# its default.

CFG_PANEL_APP_KEYS="DIM_TIMEOUT DIM_LEVEL"

cfg_panel_app_valid() {
	case "$1" in
	DIM_TIMEOUT) printf '%s' "$2" | grep -Eq '^[0-9]{1,5}$' && [ "$2" -le 86400 ];;
	DIM_LEVEL) printf '%s' "$2" | grep -Eq '^[0-9]{1,3}$' && [ "$2" -ge 1 ] && [ "$2" -le 100 ];;
	*) return 1;;
	esac
}

# _pa_file KEY FILE: write the value of KEY to FILE when it changed, or
# remove FILE when KEY is not set.
_pa_file() {
	_pa_v=$(cfg_get "$1") || _pa_v=
	if [ -n "$_pa_v" ]; then
		[ "$(cat "$2" 2>/dev/null)" = "$_pa_v" ] || printf '%s\n' "$_pa_v" | write_override "$2" 644
	else
		rm -f "$2"
	fi
}

cfg_panel_app_apply() {
	_pa_file DIM_TIMEOUT "$RUN/dim-timeout"
	_pa_file DIM_LEVEL "$RUN/dim-level"
}
