# paths.sh: find a file of this repo by the path it has on the panel.
#   . "$(dirname "$0")/lib/paths.sh"
#   P usr/local/sbin/tsx-config     prints <repo>/base/usr/local/sbin/tsx-config
# Each package directory holds the files as they sit on the panel.
# TSX_ROOT is the top of the repo. The tests sit in $TSX_ROOT/tests.
TSX_ROOT=${TSX_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
TSX_PKGS="base kiosk setup ha sendspin buttons autoupdate rescue splash ledbar panel-app bench"
P() {
	for _p in $TSX_PKGS; do
		[ -e "$TSX_ROOT/$_p/$1" ] && { printf '%s\n' "$TSX_ROOT/$_p/$1"; return 0; }
	done
	printf '%s\n' "$TSX_ROOT/missing/$1"
	return 1
}

# defaults_dir: a folder with a link to each defaults file of the packages
# (usr/local/share/tsx/defaults/NAME). Tests give it to the programs as
# TSX_DEFAULTS_DIR, in place of /usr/local/share/tsx/defaults on the panel.
defaults_dir() {
	_dd=${TMPDIR:-/tmp}/tsx-test-defaults.$(id -u)
	mkdir -p "$_dd"
	for _p in $TSX_PKGS; do
		for _f in "$TSX_ROOT/$_p"/usr/local/share/tsx/defaults/*; do
			[ -e "$_f" ] && ln -sf "$_f" "$_dd/$(basename "$_f")"
		done
	done
	printf '%s\n' "$_dd"
}
