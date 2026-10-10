# paths.sh: find a file of this repo by the path it has on the panel.
#   . "$(dirname "$0")/lib/paths.sh"
#   P usr/local/sbin/tsx-config     prints <repo>/base/usr/local/sbin/tsx-config
# Each package directory holds the files as they sit on the panel.
# TSX_ROOT is the top of the repo. The tests sit in $TSX_ROOT/tests.
TSX_ROOT=${TSX_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
TSX_PKGS="base kiosk setup ha buttons autoupdate rescue splash ledbar panel-app"
P() {
	for _p in $TSX_PKGS; do
		[ -e "$TSX_ROOT/$_p/$1" ] && { printf '%s\n' "$TSX_ROOT/$_p/$1"; return 0; }
	done
	printf '%s\n' "$TSX_ROOT/missing/$1"
	return 1
}
