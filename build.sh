#!/bin/bash
# Builds Bloc.app from the SwiftPM executable.
#   ./build.sh          release build into ./Bloc.app
#   ./build.sh debug    debug build, faster to iterate
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="Bloc.app"

# Homebrew builds run inside Homebrew's sandbox, where SwiftPM's own nested
# sandbox is rejected. The formula sets BLOC_SWIFT_FLAGS=--disable-sandbox.
FLAGS=${BLOC_SWIFT_FLAGS:-}

echo "==> compilando ($CONFIG)"
swift build -c "$CONFIG" $FLAGS

BIN="$(swift build -c "$CONFIG" $FLAGS --show-bin-path)/Bloc"
[ -f "$BIN" ] || { echo "no se encontró el binario en $BIN"; exit 1; }

echo "==> armando $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Bloc"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: enough for the app to run locally and keep a stable identity
# so the login item and the global shortcut survive rebuilds.
echo "==> firmando (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "==> listo: $(pwd)/$APP"
