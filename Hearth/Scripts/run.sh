#!/usr/bin/env bash
# One local command to build and open Hearth on macOS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Hearth's workspace is a native macOS app (SwiftUI, AppKit, Core Data, and Keychain)."
  echo "This machine cannot launch that interface."
  echo "Run the focused tests from the Hearth directory:"
  echo "  swift test"
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift 6 is required. Install it from https://www.swift.org/install/ and run ./Hearth/Scripts/run.sh again."
  exit 1
fi

swift build --product Hearth
BIN="$(swift build --show-bin-path)/Hearth"
APP="$ROOT/build/Hearth.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Hearth"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP"
open "$APP"
