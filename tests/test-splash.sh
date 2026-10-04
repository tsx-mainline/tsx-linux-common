#!/bin/sh
# Host test for splash/src/tsx-splash.c and splash/mksplash.sh (no
# framebuffer needed). The test builds the tool with the host compiler. It
# renders frames with "png -g WxH" from a synthetic splash dir: a PPM with a
# white square, and a PSF2 font whose glyphs are solid blocks. All sizes are
# made up, so the test holds no size of a real panel. It checks the pixels
# for these cases:
#  - the image centered on black
#  - the status text where the panel shows it (70 % of the height)
#  - the fill and the track of the progress bar
#  - a smaller image, centered on a bigger screen
#  - no bar with -p -1
#  - a missing font (bar only)
#  - the folder scan: the largest image that fits wins, the tie rule, the
#    names that do not count, a corrupt file, no fitting image, no folder
#  - the arguments of mksplash.sh (the rendering needs an Alpine container,
#    so the build host checks it)
# CC selects the compiler (default gcc).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
ok() { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }

${CC:-gcc} -O2 -Wall -Wextra -Werror -o "$W/tsx-splash" "$HERE/../splash/src/tsx-splash.c"
mkdir -p "$W/d"
python3 - "$W/d" <<'PY'
import struct, sys
d = sys.argv[1]
w, h = 1000, 700
px = bytearray(w * h * 3)
for y in range(345, 355):
    for x in range(495, 505):
        px[(y * w + x) * 3:(y * w + x) * 3 + 3] = b'\xff\xff\xff'
open(d + '/splash-1000x700.ppm', 'wb').write(b'P6\n# test\n1000 700\n255\n' + bytes(px))
# PSF2, 256 glyphs of 8x16, every pixel set
open(d + '/font-16.psf', 'wb').write(struct.pack('<8I', 0x864ab572, 0, 32, 0, 256, 16, 16, 8) + b'\xff' * 16 * 256)
PY

# pixel FILE X Y -> rrggbb
pixel() {
	python3 - "$@" <<'PY'
import struct, sys, zlib
b = open(sys.argv[1], 'rb').read()
assert b[:8] == b'\x89PNG\r\n\x1a\n'
o, idat, w = 8, b'', 0
while o < len(b):
    n, t = struct.unpack('>I4s', b[o:o + 8])
    c = b[o + 8:o + 8 + n]
    assert zlib.crc32(t + c) & 0xffffffff == struct.unpack('>I', b[o + 8 + n:o + 12 + n])[0], 'crc'
    if t == b'IHDR': w, h = struct.unpack('>II', c[:8])
    if t == b'IDAT': idat += c
    o += 12 + n
raw = zlib.decompress(idat)
x, y = int(sys.argv[2]), int(sys.argv[3])
row = raw[y * (w * 3 + 1):(y + 1) * (w * 3 + 1)]
assert row[0] == 0
print(row[1 + x * 3:4 + x * 3].hex())
PY
}
expect() {  # FILE X Y RRGGBB WHAT
	got=$(pixel "$1" "$2" "$3") || { bad "$5: PNG did not decode"; return; }
	[ "$got" = "$4" ] && ok "$5" || bad "$5: ($2,$3) is $got, want $4"
}

echo "== 1000x700, image + status + 50 % =="
"$W/tsx-splash" -d "$W/d" -g 1000x700 -s AB -p 50 png "$W/a.png"
expect "$W/a.png" 0 0 000000 "background black"
expect "$W/a.png" 500 350 ffffff "image centered"
expect "$W/a.png" 495 495 9aa3ad "status text at 70 % (text centered, 2 glyphs of 8)"
expect "$W/a.png" 480 495 000000 "left of the text is black"
expect "$W/a.png" 400 515 3fa7e0 "bar: filled part"
expect "$W/a.png" 600 515 1c2329 "bar: track past 50 %"
expect "$W/a.png" 319 515 000000 "bar: 36 % wide, centered (left edge)"
expect "$W/a.png" 320 515 3fa7e0 "bar: 36 % wide, centered (first pixel)"
[ "$("$W/tsx-splash" -g 1000x700 size)" = 1000x700 ] && ok "size -g" || bad "size -g"

echo "== no bar (-p -1) =="
"$W/tsx-splash" -d "$W/d" -g 1000x700 -s AB -p -1 png "$W/b.png"
expect "$W/b.png" 400 515 000000 "no bar"

echo "== 1160x780: the 1000x700 image centered, no font-24 (bar only) =="
"$W/tsx-splash" -d "$W/d" -g 1160x780 -s AB -p 100 png "$W/c.png"
expect "$W/c.png" 580 390 ffffff "smaller image centered"
expect "$W/c.png" 79 390 000000 "outside the smaller image is black"
expect "$W/c.png" 580 552 000000 "no font: no text"
expect "$W/c.png" 787 584 3fa7e0 "bar full at 100 % (last pixel)"
expect "$W/c.png" 788 584 000000 "bar full at 100 % (past the end)"

echo "== orientation: the frame upright, turned onto the framebuffer =="
mkdir -p "$W/d2"
python3 - "$W/d2" <<'PY'
import struct, sys
d = sys.argv[1]
for w, h, cx, cy in ((1000, 700, 500, 350), (700, 1000, 350, 500)):
    px = bytearray(w * h * 3)
    for y in range(cy - 5, cy + 5):
        for x in range(cx - 5, cx + 5):
            px[(y * w + x) * 3:(y * w + x) * 3 + 3] = b'\xff\xff\xff'
    open('%s/splash-%dx%d.ppm' % (d, w, h), 'wb').write(b'P6\n%d %d\n255\n' % (w, h) + bytes(px))
for n, gw, gh in ((16, 8, 16), (24, 12, 24)):
    open('%s/font-%d.psf' % (d, n), 'wb').write(struct.pack('<8I', 0x864ab572, 0, 32, 0, 256, gh * ((gw + 7) // 8), gh, gw) + b'\xff' * gh * ((gw + 7) // 8) * 256)
PY
[ "$("$W/tsx-splash" -g 1000x700 -o portrait size)" = 700x1000 ] && ok "size: portrait frame 700x1000" || bad "size -o portrait"
echo portrait-flipped > "$W/orient"
[ "$(TSX_ORIENTATION_FILE="$W/orient" "$W/tsx-splash" -g 1160x780 size)" = 780x1160 ] && ok "orientation from TSX_ORIENTATION_FILE" || bad "orientation file not read"
echo junk > "$W/orient"
[ "$(TSX_ORIENTATION_FILE="$W/orient" "$W/tsx-splash" -g 1160x780 size)" = 1160x780 ] && ok "junk orientation file: landscape" || bad "junk orientation file"
"$W/tsx-splash" -d "$W/d2" -g 1000x700 -o portrait -s AB -p 50 png "$W/p.png"
expect "$W/p.png" 350 500 ffffff "portrait png: the 700x1000 frame, image centered"
expect "$W/p.png" 345 710 9aa3ad "portrait png: status text (24 px font) at 70 % of 1000"
expect "$W/p.png" 250 738 3fa7e0 "portrait png: bar filled"
expect "$W/p.png" 400 738 1c2329 "portrait png: bar track"
"$W/tsx-splash" -d "$W/d2" -g 1000x700 -o portrait -s AB -p 50 fbpng "$W/pf.png"
expect "$W/pf.png" 500 349 ffffff "portrait on the LCD: image (3 quarter turns clockwise)"
expect "$W/pf.png" 710 354 9aa3ad "portrait on the LCD: text"
expect "$W/pf.png" 738 449 3fa7e0 "portrait on the LCD: bar"
"$W/tsx-splash" -d "$W/d2" -g 1000x700 -o portrait-flipped -s AB -p 50 fbpng "$W/qf.png"
expect "$W/qf.png" 289 345 9aa3ad "portrait-flipped on the LCD: text (1 quarter turn)"
expect "$W/qf.png" 261 250 3fa7e0 "portrait-flipped on the LCD: bar"
"$W/tsx-splash" -d "$W/d" -g 1000x700 -o landscape-flipped -s AB -p 50 fbpng "$W/lf.png"
expect "$W/lf.png" 504 204 9aa3ad "landscape-flipped on the LCD: text (half a turn)"
expect "$W/lf.png" 599 184 3fa7e0 "landscape-flipped on the LCD: bar filled part"
"$W/tsx-splash" -d "$W/d" -g 1000x700 -o landscape -s AB -p 50 fbpng "$W/l.png"
cmp -s "$W/l.png" "$W/a.png" && ok "landscape fbpng == png (no turn)" || bad "landscape fbpng differs from png"
# the mounting of the LCD (fbcon=rotate:N) adds to the turn of the orientation
"$W/tsx-splash" -d "$W/d" -g 1000x700 -o portrait-flipped -s AB -p 50 fbpng "$W/m1.png"
TSX_PANEL_ROTATE=1 "$W/tsx-splash" -d "$W/d" -g 1000x700 -o landscape -s AB -p 50 fbpng "$W/m2.png"
cmp -s "$W/m1.png" "$W/m2.png" && ok "mounting 1 + landscape == portrait-flipped" || bad "TSX_PANEL_ROTATE did not turn the frame"
echo "quiet loglevel=3 fbcon=rotate:1 root=/dev/x" > "$W/cmdline"
TSX_CMDLINE="$W/cmdline" "$W/tsx-splash" -d "$W/d" -g 1000x700 -o landscape -s AB -p 50 fbpng "$W/m3.png"
cmp -s "$W/m1.png" "$W/m3.png" && ok "fbcon=rotate:1 on the command line turns the frame" || bad "the command line mounting is not read"
TSX_PANEL_ROTATE=1 "$W/tsx-splash" -d "$W/d" -g 1000x700 -o landscape-flipped -s AB -p 50 fbpng "$W/m4.png"
"$W/tsx-splash" -d "$W/d" -g 1000x700 -o portrait -s AB -p 50 fbpng "$W/m5.png"
cmp -s "$W/m4.png" "$W/m5.png" && ok "mounting 1 + landscape-flipped == portrait (the turns add)" || bad "the turns do not add"
"$W/tsx-splash" -o sideways -g 1000x700 size 2>/dev/null && bad "-o sideways accepted" || ok "-o sideways rejected"

echo "== folder scan: the largest image that fits =="
# Every image is one solid color, so a pixel shows which file the tool drew.
# 300x200 red, 200x300 green, 120x80 blue. The decoys are bigger and yellow,
# but their names do not count. 310x230 is a PPM that is cut short.
mkdir -p "$W/d3"
python3 - "$W/d3" <<'PY'
import sys
d = sys.argv[1]
def ppm(name, w, h, rgb):
    open('%s/%s' % (d, name), 'wb').write(b'P6\n%d %d\n255\n' % (w, h) + bytes(rgb) * (w * h))
ppm('splash-300x200.ppm', 300, 200, (255, 0, 0))
ppm('splash-200x300.ppm', 200, 300, (0, 255, 0))
ppm('splash-120x80.ppm', 120, 80, (0, 0, 255))
for decoy in ('splash-0400x300.ppm', 'splash-400x300.ppm.bak', 'splash-400x300.png', 'splash-wide.ppm', 'splash-400x.ppm', 'splash--400x300.ppm', 'splash- 400x300.ppm', 'splash-400x300.ppm~'):
    ppm(decoy, 400, 300, (255, 255, 0))
open(d + '/splash-310x230.ppm', 'wb').write(b'P6\n310 230\n255\n' + b'\xff' * 100)
PY
scan() {  # WxH -> png of that screen without text and bar
	"$W/tsx-splash" -d "$W/d3" -g "$1" -p -1 png "$W/s-$1.png"
}
scan 320x240
expect "$W/s-320x240.png" 160 120 ff0000 "320x240: 300x200 wins (310x230 is cut short, 200x300 does not fit)"
expect "$W/s-320x240.png" 10 20 ff0000 "320x240: the image starts at (10,20)"
expect "$W/s-320x240.png" 9 20 000000 "320x240: black left of the image"
expect "$W/s-320x240.png" 10 19 000000 "320x240: black above the image"
expect "$W/s-320x240.png" 309 219 ff0000 "320x240: the image ends at (309,219)"
expect "$W/s-320x240.png" 310 219 000000 "320x240: black right of the image"
scan 240x320
expect "$W/s-240x320.png" 120 160 00ff00 "240x320: 200x300 wins"
expect "$W/s-240x320.png" 20 10 00ff00 "240x320: the image starts at (20,10)"
expect "$W/s-240x320.png" 19 10 000000 "240x320: black left of the image"
scan 300x300
expect "$W/s-300x300.png" 150 150 ff0000 "300x300: the same area, the wider image (300x200) wins"
expect "$W/s-300x300.png" 0 50 ff0000 "300x300: 300x200 starts at (0,50)"
expect "$W/s-300x300.png" 0 49 000000 "300x300: black above the image"
scan 300x200
expect "$W/s-300x200.png" 0 0 ff0000 "300x200: the exact size fills the frame (top left)"
expect "$W/s-300x200.png" 299 199 ff0000 "300x200: the exact size fills the frame (bottom right)"
scan 130x90
expect "$W/s-130x90.png" 65 45 0000ff "130x90: only 120x80 fits"
scan 100x100
expect "$W/s-100x100.png" 50 50 000000 "100x100: no image fits, the frame stays black"
"$W/tsx-splash" -d "$W/none" -g 320x240 -p -1 png "$W/s-none.png" && ok "no folder: exit 0" || bad "a missing folder is an error"
expect "$W/s-none.png" 160 120 000000 "no folder: the frame stays black"
scan 1000x900
expect "$W/s-1000x900.png" 500 450 ff0000 "1000x900: the largest valid image (300x200) wins, the cut file is skipped"
rm -f "$W/d3/splash-310x230.ppm"
scan 320x240
expect "$W/s-320x240.png" 160 120 ff0000 "320x240 without the cut file: 300x200 wins"

echo "== mksplash.sh arguments =="
MK=$HERE/../splash/mksplash.sh
sh -n "$MK" && ok "mksplash.sh: syntax" || bad "mksplash.sh: syntax"
mkerr() {  # WHAT ARGS... : the script must stop with status 2 before it installs anything
	what=$1; shift
	set +e; sh "$MK" "$@" > "$W/mk.out" 2>&1; rc=$?; set -e
	[ "$rc" = 2 ] && ok "mksplash.sh $what: status 2" || bad "mksplash.sh $what: status $rc, want 2 ($(head -n 1 "$W/mk.out"))"
}
mkerr "no arguments"
mkerr "no sizes" "$W/o"
for bad_size in 1280 x800 1280x 0x800 1280x0 01280x800 1280x080 12a0x800 1280x800x1 1280X800 -5x4 "1280 800" 1.5x2; do
	mkerr "size '$bad_size'" "$W/o" 640x480 "$bad_size"
done
[ ! -e "$W/o" ] && ok "mksplash.sh: no output folder for bad arguments" || bad "mksplash.sh made a folder for bad arguments"
# Good sizes pass the check. A stub "apk" stops the script right after it.
mkdir -p "$W/stub"
printf '#!/bin/sh\necho "$@" > "%s/apk.args"\nexit 77\n' "$W" > "$W/stub/apk"
chmod +x "$W/stub/apk"
set +e; PATH="$W/stub:$PATH" sh "$MK" "$W/o" 1280x800 800x1280 640x480 7x9 100000x2 > "$W/mk.out" 2>&1; rc=$?; set -e
[ "$rc" = 77 ] && [ -s "$W/apk.args" ] && ok "mksplash.sh: good sizes reach the package install" || bad "mksplash.sh: good sizes, status $rc, want 77 ($(head -n 1 "$W/mk.out"))"
# The script must not hold a size list. Comments may give an example.
if grep -v '^[[:space:]]*#' "$MK" | grep -q -E '[0-9]{3,}x[0-9]{3,}'; then
	bad "mksplash.sh holds a size in its code"
else
	ok "mksplash.sh holds no size in its code"
fi

echo "== bad usage =="
"$W/tsx-splash" -g 0x0 png "$W/x.png" 2>/dev/null && bad "-g 0x0 accepted" || ok "-g 0x0 rejected"
"$W/tsx-splash" frobnicate 2>/dev/null && bad "unknown command accepted" || ok "unknown command rejected"

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-splash || echo FAIL test-splash
exit $F
