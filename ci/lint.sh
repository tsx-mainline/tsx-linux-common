#!/bin/bash
# Syntax and smoke lint for the whole repo. It needs no hardware and no build.
# Run it the way CI does: ci/lint.sh
#   - every script with a "#!/bin/sh" shebang must pass `busybox sh -n`.
#     This is the shell that runs on the panel, so bash syntax is not allowed.
#   - every script with a "#!/bin/bash" shebang must pass `bash -n`
#   - every *.py file must byte-compile
#   - every file in an etc/init.d directory must be executable (OpenRC
#     refuses a service script without the x bit)
#   - the package directories hold no proprietary file (ci/check-no-proprietary.sh)
#   - the relative links of the docs resolve
# `python3 -m py_compile` writes a __pycache__ directory. The script removes
# those directories again at the end.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0

# Classify by the first line of the file. Do not grep the content: some
# scripts embed a "#!/bin/sh" heredoc for a script that they generate.
sh_files=() bash_files=()
while IFS= read -r -d '' f; do
	case "$(head -c 4096 "$f" 2>/dev/null | tr -d '\0' | head -n1)" in
	'#!/bin/sh') sh_files+=("$f");;
	'#!/bin/bash') bash_files+=("$f");;
	esac
done < <(find . -type f -not -path './.git/*' -print0)

echo "== busybox sh -n (${#sh_files[@]} scripts) =="
for f in "${sh_files[@]}"; do
	busybox sh -n "$f" || { echo "FAIL: busybox sh -n $f"; fail=1; }
done

echo "== bash -n (${#bash_files[@]} scripts) =="
for f in "${bash_files[@]}"; do
	bash -n "$f" || { echo "FAIL: bash -n $f"; fail=1; }
done

echo "== python3 -m py_compile =="
while IFS= read -r f; do
	python3 -m py_compile "$f" || { echo "FAIL: py_compile $f"; fail=1; }
done < <(find . -name '*.py' -not -path './.git/*')
find . -name __pycache__ -not -path './.git/*' -exec rm -rf {} + 2>/dev/null

echo "== init scripts are executable =="
for f in */etc/init.d/*; do
	[ -x "$f" ] || { echo "FAIL: $f is not executable"; fail=1; }
done

echo "== no proprietary file =="
ci/check-no-proprietary.sh || { echo "FAIL: proprietary file"; fail=1; }

echo "== docs: relative links and anchors resolve =="
python3 ci/check-doc-links.py || { echo "FAIL: doc links"; fail=1; }

[ $fail -eq 0 ] && echo "lint OK" || echo "lint FAILED"
exit $fail
