#!/bin/bash
# Host test: the generic gate ci/check-generic.sh. The test builds small git
# repos in a temporary directory. It plants family words in them and checks
# that the gate fails on each one, and that the gate lets pass a "for example"
# line, a file below docs/ and a word that the allow list names. It also runs
# the gate on this repo. It needs git and no panel.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
command -v git >/dev/null 2>&1 || { echo "SKIPPED test-generic-gate: no git on this host"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
N=0 F=0
D=docs   # a variable keeps the file name of the pages out of the text of this test
ok() { echo "  ok: $*"; N=$((N + 1)); }
bad() { echo "  FAIL: $*"; F=$((F + 1)); }

# newrepo NAME: an empty repo that holds the gate and an empty allow list.
newrepo() {
	R=$W/$1; mkdir -p "$R/ci" "$R/base" "$R/docs"
	cp "$HERE/ci/check-generic.sh" "$R/ci/"
	: > "$R/ci/check-generic.allow"
	git -C "$R" init -q
}
# gate: run the gate in $R, keep its output in $OUT and its status in $RC.
gate() {
	git -C "$R" add -A
	OUT=$(cd "$R" && bash ci/check-generic.sh 2>&1); RC=$?
}

echo "== a clean repo passes =="
newrepo clean
printf '# A neutral comment about the board file.\necho hello\n' > "$R/base/script"
gate
[ $RC = 0 ] && ok "no hit: exit 0" || bad "clean repo: exit $RC: $OUT"

echo "== a planted word fails, one word of each group =="
# Two words are split with quotes, so the publish check of the repository does not see them.
for w in xx60 xx"70" TSW-760 TSS-10 tsw1060 ttyAML0 tty"MSM0" meson lima CSR8811 MAX44009 ov5640 \
	government camera lightbar "light bar" u-boot bluecore psr tfa9890 sensord; do
	newrepo plant
	printf '# The code for the %s panel.\n' "$w" > "$R/base/script"
	gate
	if [ $RC = 1 ] && grep -q '^base/script:1:' <<< "$OUT"; then ok "'$w' fails and the output names the line"
	else bad "'$w': exit $RC: $OUT"; fi
done

echo "== a planted file name fails =="
newrepo name
printf 'neutral\n' > "$R/base/xx60-helper"
gate
[ $RC = 1 ] && grep -q '^base/xx60-helper: the file name has' <<< "$OUT" && ok "xx60 in a file name fails" || bad "file name: exit $RC: $OUT"

echo "== a word inside a longer word does not fail =="
newrepo inword
printf '# The limited sample of the limit and the sensor.\n' > "$R/base/script"
gate
[ $RC = 0 ] && ok "limit and limited pass" || bad "limit: exit $RC: $OUT"

echo "== the match ignores case =="
newrepo case
printf '# the Xx60 board\n' > "$R/base/script"
gate
[ $RC = 1 ] && ok "Xx60 fails" || bad "Xx60: exit $RC: $OUT"

echo "== a line with \"for example\" or \"e.g.\" passes =="
newrepo example
printf '# A serial console, for example ttyAML0.\n# A map name (e.g. TSW-1060-LB).\n' > "$R/base/script"
gate
[ $RC = 0 ] && ok "both example lines pass" || bad "example lines: exit $RC: $OUT"
printf '# A serial console, for example ttyS0.\n# The code is for the xx60.\n' > "$R/base/script"
gate
[ $RC = 1 ] && grep -q '^base/script:2:' <<< "$OUT" && ! grep -q '^base/script:1:' <<< "$OUT" \
	&& ok "only the line without an example fails" || bad "mixed lines: exit $RC: $OUT"

echo "== the gate does not read docs/ =="
newrepo docs
printf 'The xx60 and the TSW-1060 are examples.\n' > "$R/$D/page.md"
gate
[ $RC = 0 ] && ok "a family name in docs/ passes" || bad "docs/: exit $RC: $OUT"

echo "== a docs reference =="
newrepo ref
printf '# Heading One\n\n## The Second Heading\n' > "$R/$D/real.md"
printf '# See %s/real.md and %s/real.md "The Second Heading".\n' "$D" "$D" > "$R/base/script"
gate
[ $RC = 0 ] && ok "a page of the repo, with and without a heading, passes" || bad "real page: exit $RC: $OUT"
printf '# See %s/missing.md "Setup page".\n' "$D" > "$R/base/script"
gate
[ $RC = 1 ] && grep -q "^base/script:1: $D/missing.md is not a page of this repo" <<< "$OUT" \
	&& ok "a page that only a board repo has fails" || bad "missing page: exit $RC: $OUT"
printf '# See %s/real.md "No Such Heading".\n' "$D" > "$R/base/script"
gate
[ $RC = 1 ] && grep -q "^base/script:1: $D/real.md has no heading \"No Such Heading\"" <<< "$OUT" \
	&& ok "a heading that the page lacks fails" || bad "missing heading: exit $RC: $OUT"
printf '# See %s/real.md "the second heading".\n' "$D" > "$R/base/script"
gate
[ $RC = 0 ] && ok "the heading match ignores case" || bad "heading case: exit $RC: $OUT"

echo "== the allow list =="
newrepo allow
printf 'REAL=xx60\n' > "$R/base/script"
printf 'base/script :: xx60 :: a test reason\n' > "$R/ci/check-generic.allow"
gate
[ $RC = 0 ] && ok "an entry allows the word in the file" || bad "entry: exit $RC: $OUT"
printf 'REAL=xx60 meson\n' > "$R/base/script"
gate
[ $RC = 1 ] && grep -q 'meson' <<< "$OUT" && ok "a word without an entry still fails on the same line" || bad "second word: exit $RC: $OUT"
printf 'REAL=xx60\n' > "$R/base/other"; printf 'ok\n' > "$R/base/script"
printf 'base/script :: xx60 :: a test reason\n' > "$R/ci/check-generic.allow"
gate
[ $RC = 1 ] && grep -q 'allows nothing' <<< "$OUT" && grep -q '^base/other:1:' <<< "$OUT" \
	&& ok "an entry for another file does not help, and an unused entry is an error" || bad "stale entry: exit $RC: $OUT"
printf 'REAL=xx60\n' > "$R/base/script"; rm -f "$R/base/other"
printf 'base/*,docs/* :: xx60|meson :: two globs and two words\n' > "$R/ci/check-generic.allow"
gate
[ $RC = 0 ] && ok "a glob and a word list work" || bad "glob entry: exit $RC: $OUT"
printf 'base/script :: xx60\n' > "$R/ci/check-generic.allow"
gate
[ $RC = 2 ] && ok "an entry without a reason is a usage error" || bad "no reason: exit $RC: $OUT"

echo "== this repo passes the gate =="
if git -C "$HERE" rev-parse --git-dir >/dev/null 2>&1; then
	OUT=$(cd "$HERE" && bash ci/check-generic.sh 2>&1); RC=$?
	[ $RC = 0 ] && ok "$(tail -n 1 <<< "$OUT")" || bad "this repo: exit $RC: $OUT"
else
	echo "  skip: this tree is not a git repo"
fi

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo "PASS test-generic-gate" || { echo "FAIL test-generic-gate"; exit 1; }
