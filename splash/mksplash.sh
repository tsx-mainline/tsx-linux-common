#!/bin/sh
# Render the boot splash for the screen sizes on the command line into OUTDIR:
#   splash-WxH.{png,ppm}        one frame for each size
#   font-16.psf, font-24.psf    Terminus console fonts for the status line
# The script has no list of sizes. The caller gives them, for example:
#   mksplash.sh OUTDIR 1280x800 800x1280
# Each size is WIDTHxHEIGHT in decimal, without a leading zero. Give the
# upright size of each screen. For a panel that hangs in portrait, also give
# the portrait size. tsx-splash turns the frame onto the landscape LCD (see
# docs/rootfs.md "Orientation"). tsx-splash draws the largest image that fits
# the screen, so an unused size costs only space.
# The picture scales with the size. The Tux scale is the short side divided
# by 300, but at least 1. The word mark is 7/16 of the long side wide, but
# at most 3/4 of the short side.
# The .ppm files and the fonts go into the initramfs (tsx-splash draws them on
# /dev/fb0). The .png files go into the rootfs (the compositor background).
# This script runs inside an Alpine container (the initramfs and rootfs
# builds). It installs its own tools there (rsvg-convert, py3-pillow,
# font-terminus, and font-jetbrains-mono for the word mark). It never
# installs them into the image that the build makes.
#   mksplash.sh OUTDIR WxH...
set -eu

usage() { echo "usage: mksplash.sh OUTDIR WxH..." >&2; exit 2; }

# Return 0 for two decimal numbers without a leading zero, joined by an x.
size_ok() {
	case $1 in
	"" | *[!0-9x]* | *x*x* | x* | *x | 0* | *x0*) return 1 ;;
	*x*) return 0 ;;
	esac
	return 1
}

[ $# -ge 2 ] || usage
OUT=$1; shift
for s in "$@"; do
	size_ok "$s" || { echo "mksplash.sh: bad size '$s' (want WIDTHxHEIGHT)" >&2; usage; }
done

HERE=$(cd "$(dirname "$0")" && pwd)
apk add -q --no-cache rsvg-convert py3-pillow font-terminus font-jetbrains-mono fontconfig >/dev/null
# The word mark is text. Do not render it in a fallback font.
fc-match -f '%{file}\n' 'JetBrains Mono:bold' | grep -q 'JetBrainsMono-Bold\.ttf$' ||
	{ echo "mksplash.sh: JetBrains Mono Bold not found by fontconfig" >&2; exit 1; }
mkdir -p "$OUT"; T=$(mktemp -d)
for s in "$@"; do
	w=${s%x*}; h=${s#*x}
	if [ "$w" -ge "$h" ]; then long=$w; short=$h; else long=$h; short=$w; fi
	scale=$((short / 300)); [ "$scale" -ge 1 ] || scale=1
	mark=$((long * 7 / 16)); [ "$mark" -le $((short * 3 / 4)) ] || mark=$((short * 3 / 4))
	rsvg-convert -w "$mark" "$HERE/tsx-linux-mark.svg" -o "$T/mark.png"
	python3 "$HERE/compose.py" "$w" "$h" "$scale" "$T/mark.png" "$HERE/tux-80.png" "$OUT/splash-${w}x${h}"
done
# Terminus (SIL OFL 1.1) uses the ISO 8859-1 code page, so ASCII maps 1:1 to glyphs.
zcat /usr/share/consolefonts/ter-116n.psf.gz > "$OUT/font-16.psf"
zcat /usr/share/consolefonts/ter-124n.psf.gz > "$OUT/font-24.psf"
rm -rf "$T"
ls -l "$OUT"
