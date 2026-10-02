#!/bin/bash
# 로고 산출물 재생성 — 외부 툴 없이(swiftc + iconutil 만).
#   captures/logo-candidates.png  : 메뉴바 후보 3개 비교 시트 (라이트/다크 · 실제 크기 · 8배)
#   Resources/AppIcon.icns        : 앱 아이콘 (LogoImage.current 글리프, 다크 초록 인광)
# 사용: scripts/logo-assets.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 여러 파일을 컴파일할 때 최상위 문장은 main.swift 에만 허용되므로 렌더러를 그 이름으로 복사한다.
cp "$ROOT/scripts/render-logo-assets.swift" "$WORK/main.swift"
arch -arm64 swiftc -O -framework AppKit \
  "$ROOT/Sources/NotchIsland/Support/LogoImage.swift" "$WORK/main.swift" \
  -o "$WORK/render-logo-assets"

mkdir -p "$ROOT/captures"
"$WORK/render-logo-assets" sheet "$ROOT/captures/logo-candidates.png"
"$WORK/render-logo-assets" icon "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"
echo "WROTE: $ROOT/Resources/AppIcon.icns"
