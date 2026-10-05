#!/bin/bash
# The generic gate: this repo holds the shared software of all panel families.
# It names no family, no panel model and no family chip outside docs/. The
# board facts come from the board file of the family repo.
#   ci/check-generic.sh
# The script runs `git grep` for the words below in every file outside docs/.
# It also checks the file names.
# A hit passes in two cases:
#   1. The line has "for example" or "e.g.". An example may name a family.
#   2. ci/check-generic.allow allows the word in that file. Each entry has a
#      reason. Keep the list short.
# An entry that allows nothing is an error, so the list shrinks with the code.
# The gate also checks that a docs/NAME.md in a comment is a page of this repo.
# Exit status: 0 no hit, 1 a hit or a stale entry, 2 a usage error.
set -u
cd "$(dirname "$0")/.."
ALLOW=ci/check-generic.allow

# Extended regular expressions, matched without regard to case.
WORDS=(
	'xx[0-9]+'                                       # family names
	'\bts[ws]\b' '\bts[ws][0-9]'                     # panel models
	'tty(aml|msm)'                                   # serial consoles of a family
	'meson|amlogic|msm8[0-9]+|apq8[0-9]+'            # SoC names
	'\blima\b|\bmali\b'                              # GPU drivers of a family
	'u-?boot'                                        # the bootloader of one family
	'csr8811|bluecore|\bpsr\b|psrkind'               # the Bluetooth chip of one family
	'max44009|ov5640|ft5x06|mp3309c|zl38[0-9]+|tfa98[0-9]+'   # chips of one family
	'lp5024|aw21024|lightbar|light bar'              # the second light bar path
	'camera|take_snapshot|last_snapshot'             # the camera of one family
	'government'                                     # a hw.conf value of one family
	'sensord'                                        # the sensor daemon of one family
)
RE=$(IFS='|'; echo "${WORDS[*]}")
EXAMPLE='for example|e\.g\.'

# Read the allow list. Fields: PATH-GLOBS :: TOKEN-REGEX :: REASON.
# PATH-GLOBS are separated by commas. TOKEN-REGEX must match a whole hit word.
a_path=() a_tok=() a_used=()
if [ -r "$ALLOW" ]; then
	n=0
	while IFS= read -r line; do
		n=$((n + 1))
		case $line in ''|'#'*) continue;; esac
		p=${line%% :: *} rest=${line#* :: }
		t=${rest%% :: *} why=${rest#* :: }
		if [ "$p" = "$line" ] || [ "$rest" = "$t" ] || [ -z "$p" ] || [ -z "$t" ] || [ -z "$why" ]; then
			echo "$ALLOW:$n: need three fields: PATH-GLOBS :: TOKEN-REGEX :: REASON" >&2
			exit 2
		fi
		a_path+=("$p") a_tok+=("$t") a_used+=(0)
	done < "$ALLOW"
fi

# allowed PATH TOKEN: succeed when an entry allows the word in the file.
allowed() {
	local i g globs
	for i in "${!a_path[@]}"; do
		grep -qiE "^(${a_tok[$i]})\$" <<< "$2" || continue
		IFS=, read -ra globs <<< "${a_path[$i]}"
		for g in "${globs[@]}"; do
			# shellcheck disable=SC2053
			if [[ $1 == $g ]]; then a_used[$i]=1; return 0; fi
		done
	done
	return 1
}

fail=0 hits=0
while IFS= read -r hit; do
	path=${hit%%:*} rest=${hit#*:}
	lineno=${rest%%:*} text=${rest#*:}
	grep -qiE "$EXAMPLE" <<< "$text" && continue
	bad=
	while IFS= read -r tok; do
		allowed "$path" "$tok" || bad="$bad $tok"
	done < <(grep -oiE "$RE" <<< "$text")
	if [ -n "$bad" ]; then
		echo "$path:$lineno:${bad}: $text"
		hits=$((hits + 1))
	fi
done < <(git grep -nIiE "$RE" -- . ':(exclude)docs' ':(exclude)ci/check-generic.sh' ':(exclude)ci/check-generic.allow')

# The same words in a file name.
while IFS= read -r path; do
	bad=
	while IFS= read -r tok; do
		allowed "$path" "$tok" || bad="$bad $tok"
	done < <(grep -oiE "$RE" <<< "$path")
	if [ -n "$bad" ]; then
		echo "$path: the file name has${bad}"
		hits=$((hits + 1))
	fi
done < <(git ls-files -- . ':(exclude)docs' ':(exclude)ci/check-generic.sh' ':(exclude)ci/check-generic.allow')

# A comment can name a page of docs/. The page must exist in this repo, and a
# quoted heading (docs/NAME.md "Heading") must be a heading of the page. A
# page that only the board repositories have is not a target. Name the board
# docs in words instead.
while IFS= read -r hit; do
	path=${hit%%:*} rest=${hit#*:}
	lineno=${rest%%:*} ref=${rest#*:}
	doc=${ref%%.md*}.md
	if ! git ls-files --error-unmatch -- "$doc" > /dev/null 2>&1; then
		echo "$path:$lineno: $doc is not a page of this repo"
		hits=$((hits + 1))
		continue
	fi
	case $ref in *\"*)
		heading=${ref#*\"} heading=${heading%\"*}
		if ! sed -nE 's/^#+ +//p' "$doc" | grep -qixF -- "$heading"; then
			echo "$path:$lineno: $doc has no heading \"$heading\""
			hits=$((hits + 1))
		fi;;
	esac
done < <(git grep -noIE 'docs/[A-Za-z0-9_.-]+\.md( ?"[^"]*")?' -- . ':(exclude)docs' ':(exclude)ci/check-generic.sh' ':(exclude)ci/check-generic.allow')

for i in "${!a_path[@]}"; do
	if [ "${a_used[$i]}" = 0 ]; then
		echo "$ALLOW: the entry '${a_path[$i]} :: ${a_tok[$i]}' allows nothing. Remove it."
		fail=1
	fi
done
if [ $hits -gt 0 ]; then
	echo "generic gate FAILED: $hits problem(s)."
	echo "A family word: reword the line, give it a \"for example\", or add an entry with a reason to $ALLOW."
	echo "A docs reference: name a page of this repo, or name the board docs in words."
	fail=1
fi
[ $fail = 0 ] && echo "generic gate OK (${#a_path[@]} allow entries)"
exit $fail
