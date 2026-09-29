#!/bin/bash
# Assemble a local "Synology Drive Unstuckerator.app" and ad-hoc sign it.
# Usage: Scripts/package-app.sh [destination.app]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Synology Drive Unstuckerator"
DEST="${1:-$HOME/Applications/$APP_NAME.app}"
CONFIGURATION="${CONFIGURATION:-release}"

swift build --package-path "$ROOT" --configuration "$CONFIGURATION" --product Unstuckerator
BIN_DIR="$(swift build --package-path "$ROOT" --configuration "$CONFIGURATION" --product Unstuckerator --show-bin-path)"
BIN="$BIN_DIR/Unstuckerator"

if [[ ! -x "$BIN" ]]; then
  echo "Build did not produce $BIN" >&2
  exit 1
fi

mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$ROOT/AppLauncher/Info.plist" "$DEST/Contents/Info.plist"
cp "$ROOT/App/Resources/AppIcon.icns" "$DEST/Contents/Resources/AppIcon.icns"
cp "$ROOT/App/Resources/DockMark.png" "$DEST/Contents/Resources/DockMark.png"
cp "$ROOT/App/Resources/MenuMark.png" "$DEST/Contents/Resources/MenuMark.png"
cp "$BIN" "$DEST/Contents/MacOS/$APP_NAME"
chmod +x "$DEST/Contents/MacOS/$APP_NAME"
codesign --force --sign - "$DEST"
echo "Built $DEST"

# OPEN=0 builds the app without quitting a copy that is already running.
if [[ "${OPEN:-1}" == "1" ]]; then
  # Replace only this app. Match the executable path so a short name cannot hit Synology.
  if pgrep -x Unstuckerator >/dev/null; then
    killall Unstuckerator || true
    sleep 0.4
  fi
  needle="/Contents/MacOS/$APP_NAME"
  ps -ax -o pid=,command= | while read -r pid command; do
    case "$command" in
      *"$needle"*) kill "$pid" || true ;;
    esac
  done
  sleep 0.4
  legacy="$HOME/Applications/Unstuckerator.app"
  if [[ "$DEST" != "$legacy" && -d "$legacy" ]]; then
    rm -rf "$legacy"
  fi
  # Launch Services often returns -600 on the first open right after signing.
  open "$DEST" || true
  sleep 1
  open "$DEST"
fi
