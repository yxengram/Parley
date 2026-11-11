#!/bin/zsh
# Checks the interface translations (Resources/*.lproj) strictly: every key the Swift sources use
# must have a Simplified Chinese value. swift test runs the same check without that requirement
# (Tests/ParleyAppTests/LocalizationTests.swift), so a missing translation fails only here.
#
#   tools/test_l10n.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
/usr/bin/python3 -I "$ROOT/tools/l10n_check.py" check
