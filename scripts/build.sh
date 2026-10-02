#!/bin/bash
# Notch Island 빌드: swift build → .app 번들 조립 → 임시(ad-hoc) 서명.
# 사용: scripts/build.sh [release|debug]   결과: build/Notch Island.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
# xcode-select 가 CLT 를 가리키는 머신이라 Xcode 를 명시한다
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

arch -arm64 swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(arch -arm64 swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/NotchIsland"

APP="$ROOT/build/Notch Island.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotchIsland"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"   # 재생성: scripts/logo-assets.sh
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "BUILT: $APP"
