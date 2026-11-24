#!/usr/bin/env bash
# Runs EnergyCore unit tests. With only Command Line Tools installed, SwiftPM does not find
# Testing.framework on its own, so the framework path is passed explicitly. With Xcode it is harmless.
set -euo pipefail
cd "$(dirname "$0")/../Packages/EnergyCore"
DEV="$(xcode-select -p)"
case "$DEV" in
  *CommandLineTools*) F="$DEV/Library/Developer/Frameworks"; L="$DEV/Library/Developer/usr/lib" ;;
  *) F="$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks"; L="$DEV/Platforms/MacOSX.platform/Developer/usr/lib" ;;
esac
exec swift test -Xswiftc -F"$F" -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
