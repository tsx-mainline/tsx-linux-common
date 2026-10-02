#!/bin/sh
# Fail if the repo holds a Crestron proprietary file: a DSP tuning container
# (.cnt), a firmware package (.puf) or a Bluetooth PSR file (.psr), or a
# directory of the vendor files. The shared software never needs them. The
# boards fetch them at install time.
#   ci/check-no-proprietary.sh
set -eu
cd "$(dirname "$0")/.."
hits=$(git ls-files | grep -Ei '\.(cnt|puf|psr)$|(^|/)(tfa9890|csr8811)/' || true)
if [ -n "$hits" ]; then
	echo "proprietary files in the repo:"
	echo "$hits"
	exit 1
fi
echo "no proprietary files"
