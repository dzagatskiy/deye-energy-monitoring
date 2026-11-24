#!/usr/bin/env bash
# Builds the app + widget extension for the iOS Simulator using /Applications/Xcode.app,
# without changing the system-wide xcode-select setting.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
exec xcodebuild -project EnergyMonitor.xcodeproj -scheme EnergyMonitor \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY=- "$@" build
