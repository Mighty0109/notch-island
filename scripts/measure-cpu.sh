#!/bin/bash
# CPU 측정 (실제 마우스·키·클릭을 일절 만들지 않는다): 측정용 앱 인스턴스를 `--sim-pointer <시나리오>` 로 띄우면
# 앱 안의 타이머가 가짜 좌표를 90Hz 로 evaluatePointer 에 넣는다(전역 마우스 모니터가 부르는 것과 같은 경로).
# 그 모드의 인스턴스는 실제 이벤트 모니터·메뉴바 아이콘이 없고 패널이 투명·항상 클릭 통과라 화면에도 안 보인다.
# 별도 defaults suite 를 쓰고(사용자 설정 무영향), `ps -o cputime` 차분 + RSS 로 표를 낸다. 측정 PID 만 종료한다.
# 한계: WindowServer 가 실제 커서 이동을 앱에 배달하는 비용·AppKit 툴팁 추적은 빠진다(README "측정의 한계").
#
# 사용: scripts/measure-cpu.sh [--app PATH] [--only idle,far-move,island-move,island-hover,pinned-idle,hover-cycle] [--scale 0.5]
#                             [--window-events] [--profile DIR]
#   --window-events  섬 위 좌표마다 패널 창에도 같은 mouseMoved 를 앱 안에서 보낸다(SwiftUI 이벤트 처리 비용 근사)
#   --profile DIR    각 시나리오 측정 창에 `sample` 을 붙여 DIR/<시나리오>.txt 로 남긴다(이때 CPU 값은 무효)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Notch Island.app"
ONLY=""; SCALE=1; WINEV=0; PROFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --scale) SCALE="$2"; shift 2 ;;
    --window-events) WINEV=1; shift ;;
    --profile) PROFILE="$2"; shift 2 ;;
    *) echo "모르는 인자: $1" >&2; exit 2 ;;
  esac
done
BIN="$APP/Contents/MacOS/NotchIsland"
[ -x "$BIN" ] || { echo "앱이 없다: $APP" >&2; exit 1; }
SUITE="com.mighty.notch-island.measure"
PID=""
cleanup() { [ -n "$PID" ] && kill "$PID" 2>/dev/null || true; defaults delete "$SUITE" 2>/dev/null || true; }
trap cleanup EXIT

# 이름|제목|측정 초|호버|추가 인자|목표
SCENARIOS=(
  "idle|접힘·idle|60|true||< 0.4%"
  "far-move|접힘·far-move(패널 밖 이동)|30|true||< 0.8%"
  "island-move|접힘·island-move(섬 위 이동, 호버 펼침 꺼서 접힘 유지)|30|false||< 3%"
  "pinned-idle|펼침 고정·idle|60|true|--phase=pinned|< 2%"
  "island-hover|섬 위 이동·호버 켬(미리보기로 펼쳐진 채 유지)|30|true||(참고)"
  "hover-cycle|섬 위 머물기 1.2초 ↔ 밖 0.8초 반복(열고 닫기)|30|true||(참고)"
)

cpu_secs() { ps -o cputime= -p "$1" | python3 -c 'import sys;t=sys.stdin.read().strip();p=[float(x) for x in t.split(":")];s=0
for x in p: s=s*60+x
print(s)'; }
now() { python3 -c 'import time;print(time.time())'; }

echo "앱: $APP  배율 $SCALE  창 이벤트 $([ $WINEV = 1 ] && echo 켬 || echo 끔)  $([ -n "$PROFILE" ] && echo '[프로파일 실행 — CPU 값 무효]')"
ROWS=()
for sc in "${SCENARIOS[@]}"; do
  IFS='|' read -r name title secs hover extra goal <<<"$sc"
  if [ -n "$ONLY" ] && [[ ",$ONLY," != *",$name,"* ]]; then continue; fi
  secs=$(python3 -c "print(max(5,int($secs*$SCALE)))")
  defaults delete "$SUITE" 2>/dev/null || true
  defaults write "$SUITE" hoverExpand -bool "$hover"
  defaults write "$SUITE" alertsEnabled -bool false
  args=(--sim-pointer "$name"); [ "$name" = island-hover ] && args=(--sim-pointer island-move)
  [ -n "$extra" ] && args+=("$extra")
  [ "$WINEV" = 1 ] && args+=(--sim-window-events)
  NOTCH_ISLAND_DEFAULTS_SUITE="$SUITE" "$BIN" "${args[@]}" >/dev/null 2>&1 &
  PID=$!
  sleep "$([ -n "$extra" ] && echo 10 || echo 8)"        # 워밍업: 첫 수집 기준점·패널·고정 전이
  kill -0 "$PID" 2>/dev/null || { echo "  [$name] 프로세스가 죽었다"; PID=""; continue; }
  SAMP=""
  if [ -n "$PROFILE" ]; then mkdir -p "$PROFILE"; /usr/bin/sample "$PID" "$secs" 1 -file "$PROFILE/$name.txt" >/dev/null 2>&1 & SAMP=$!; sleep 0.3; fi
  c0=$(cpu_secs "$PID"); w0=$(now)
  sleep "$secs"
  c1=$(cpu_secs "$PID"); w1=$(now)
  rss=$(ps -o rss= -p "$PID" | tr -d ' ')
  [ -n "$SAMP" ] && wait "$SAMP" || true
  kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; PID=""
  row=$(python3 -c "print('| %s | %ds | %.2f%% | %s | %.1fMB |' % ('$title', $secs, ($c1-$c0)/($w1-$w0)*100, '$goal', $rss/1024))")
  echo "  $row"
  ROWS+=("$row")
done
echo
echo "| 상황 | 시간 | 평균 CPU | 목표 | RSS |"
echo "|---|---|---|---|---|"
printf '%s\n' "${ROWS[@]}"
