#!/bin/bash
# gen-pre-split.sh: store the full settings files of every release before the
# split, so that tsx-conf-migrate can tell a user change from an old default.
#
# For each tag v*, and for the 10 settings files at their OLD path in /etc
# (etc/kiosk.conf and etc/tsx/NAME in any package folder), the script stores the
# content once, named by its blob hash:
#   base/usr/local/share/tsx/defaults/pre-split/NAME/<short blob hash>.conf
# Two tags with the same content give one file. The output is the same for the
# same tags. A file that already exists is not written again.
#
# Run it once more before the release tag that ships the split, so that the
# last release before the split is in the folder. Then commit the result.
set -eu
cd "$(dirname "$0")/.."
OUT=base/usr/local/share/tsx/defaults/pre-split
NAMES="kiosk.conf buttons.conf mqtt.conf esphome.conf voice.conf setup.conf autoupdate.conf ledbar.conf sendspin.conf panel-app.conf"
n=0
for tag in $(git tag -l 'v*' | sort); do
	for name in $NAMES; do
		case $name in kiosk.conf) re="(^|/)etc/kiosk\.conf$";; *) re="(^|/)etc/tsx/${name//./\\.}$";; esac
		git ls-tree -r "$tag" | awk '{ print $3 "\t" $4 }' | grep -E "	.*$re" | while IFS=$'\t' read -r blob path; do
			short=$(printf '%s' "$blob" | cut -c1-12)
			dest=$OUT/$name/$short.conf
			if [ ! -e "$dest" ]; then
				mkdir -p "$OUT/$name"
				git cat-file blob "$blob" > "$dest"
			fi
		done
	done
	n=$((n + 1))
done
echo "gen-pre-split: $n tags, $(find "$OUT" -type f | wc -l) files"
