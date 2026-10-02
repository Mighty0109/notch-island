#!/bin/bash
# 단위 테스트 전체 실행 (수집기 · 이벤트 판정 기록 재생 · 상태 머신 · 레이아웃 · 앱 성능 회귀).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# 앱 쪽 테스트가 만드는 임시 defaults(plist)를 끝에 지운다
trap 'rm -f "$HOME"/Library/Preferences/com.mighty.notch-island.tests.*.plist' EXIT
arch -arm64 swift test --package-path "$ROOT" "$@"
