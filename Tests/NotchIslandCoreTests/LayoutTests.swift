import XCTest
@testable import NotchIslandCore

final class LayoutTests: XCTestCase {
    private func layout(_ phase: IslandPhase, notchWidth: CGFloat = 250) -> IslandLayout {
        IslandLayout(phase: phase, notchWidth: notchWidth, notchHeight: 43, wingsCollapsed: .init(left: 71, right: 153), wingsOpen: .init(left: 79, right: 278), cardHeight: 400, pillWidth: 300)
    }

    func testTransparentAreaPassesThrough() {
        let l = layout(.collapsed)
        // 패널 맨 아래·좌우 가장자리 = 투명 → .none
        XCTAssertEqual(l.zone(at: CGPoint(x: 5, y: 300)), .none)
        XCTAssertEqual(l.zone(at: CGPoint(x: IslandLayout.panelWidth / 2, y: 100)), .none, "접힘일 때 노치 아래는 통과")
        XCTAssertEqual(l.zone(at: CGPoint(x: IslandLayout.panelWidth / 2, y: 20)), .head)
        XCTAssertEqual(l.zone(at: CGPoint(x: l.island.minX - 1, y: 20)), .none, "섬 왼쪽 바깥은 메뉴바 클릭 통과")
        XCTAssertEqual(l.zone(at: CGPoint(x: l.island.maxX + 1, y: 20)), .none)
    }

    /// 좌우 비대칭: 섬은 카메라(패널 가운데) 기준으로 한쪽만 길어진다. 날개 폭 = 각자 내용 폭이라 빈 검은 부분이 없다.
    func testCollapsedIslandIsAsymmetricAroundTheFixedCamera() {
        let l = layout(.collapsed)
        XCTAssertEqual(l.island.width, 250 + 71 + 153, accuracy: 0.001)
        XCTAssertEqual(l.island.minX, IslandLayout.panelWidth / 2 - 125 - 71, accuracy: 0.001)
        XCTAssertEqual(l.island.maxX, IslandLayout.panelWidth / 2 + 125 + 153, accuracy: 0.001)
        // 카메라 구간(가운데 notchWidth)은 어느 쪽 날개 폭이든 같은 자리
        XCTAssertEqual(l.head.minX + l.wings.left, IslandLayout.panelWidth / 2 - 125, accuracy: 0.001)
        XCTAssertEqual(l.head.maxX - l.wings.right, IslandLayout.panelWidth / 2 + 125, accuracy: 0.001)
    }

    /// 좌우 날개 폭이 각자 내용과 일치(±1): HeadSizing 결과 = 레이아웃 날개, 노치 폭 미만으로는 못 줄어든다
    func testWingsMatchOwnContentAndNeverDropBelowNotch() {
        let w = HeadContentWidths(cpuIcon: 14, cpuValue: 32, memIcon: 15, memValue: 24, glyph: 10, thermIcon: 10, memWord: 24, thermWord: 24, ring: 16, label: 46)
        for side in [MemorySlotFlow.Side.right, .left] {
            for open in [false, true] {
                let hw = HeadSizing.wings(w, side: side, open: open)
                let s = HeadSpacing.at(open: open)
                XCTAssertEqual(hw.left, s.wingPad * 2 + HeadSizing.leftContent(w, side: side, open: open), accuracy: 1)
                XCTAssertEqual(hw.right, s.wingPad * 2 + HeadSizing.rightContent(w, side: side, open: open), accuracy: 1)
                for nw in [185, 250] as [CGFloat] {
                    let l = IslandLayout(phase: open ? .pinned : .collapsed, notchWidth: nw, notchHeight: 43,
                                         wingsCollapsed: .init(left: hw.left, right: hw.right), wingsOpen: .init(left: hw.left, right: hw.right))
                    XCTAssertGreaterThanOrEqual(l.extents.left, nw / 2, "카메라 왼쪽까지는 늘 덮는다")
                    XCTAssertGreaterThanOrEqual(l.extents.right, nw / 2)
                    XCTAssertGreaterThanOrEqual(l.island.width, nw, "노치 하드웨어 폭 미만 0")
                }
            }
        }
        // 왼쪽 내용이 작으면 왼쪽 날개도 작다(대칭으로 맞춘 빈 부분 없음)
        let c = HeadSizing.wings(w, side: .right, open: false)
        XCTAssertLessThan(c.left, c.right)
        XCTAssertEqual(c.left, 10 + (14 + 5 + 32) + 10)
    }

    /// 메모리 칸이 좌우로 옮겨 가면 날개 폭이 각자 바뀐다(섬 외곽이 늘고 줄지만 카메라 자리는 그대로)
    func testMemoryMoveChangesEachWingNotTheCamera() {
        let w = HeadContentWidths(cpuIcon: 14, cpuValue: 32, memIcon: 15, memValue: 24, glyph: 10, thermIcon: 10, memWord: 24, thermWord: 24, ring: 16, label: 46)
        let a = HeadSizing.wings(w, side: .right, open: false), b = HeadSizing.wings(w, side: .left, open: false)
        XCTAssertGreaterThan(b.left, a.left); XCTAssertLessThan(b.right, a.right)
        for wing in [a, b] {
            let l = IslandLayout(phase: .collapsed, notchWidth: 250, notchHeight: 43, wingsCollapsed: .init(left: wing.left, right: wing.right),
                                 wingsOpen: .init(left: wing.left, right: wing.right))
            XCTAssertEqual(l.head.minX + l.wings.left + 125, IslandLayout.panelWidth / 2, accuracy: 0.001)
        }
    }

    func testOpenCardZonesAndShrinkBackToThrough() {
        let open = layout(.pinned)
        XCTAssertEqual(open.zone(at: CGPoint(x: IslandLayout.panelWidth / 2, y: 200)), .card)
        XCTAssertEqual(open.zone(at: CGPoint(x: IslandLayout.panelWidth / 2, y: 10)), .head)
        XCTAssertEqual(open.zone(at: CGPoint(x: IslandLayout.panelWidth / 2, y: 43 + 400 + 5)), .none, "카드 아래는 통과")
        // 접히면 같은 지점이 다시 통과 — 이전 크기의 입력 영역이 남지 않는다
        XCTAssertEqual(layout(.collapsed).zone(at: CGPoint(x: IslandLayout.panelWidth / 2, y: 200)), .none)
    }

    func testPillOnlyInAlertAndWinsOverIsland() {
        let a = layout(.alert)
        let pill = try! XCTUnwrap(a.pill)
        XCTAssertEqual(a.zone(at: CGPoint(x: pill.midX, y: pill.midY)), .pill)
        XCTAssertEqual(a.zone(at: CGPoint(x: pill.midX, y: pill.maxY + 30)), .none, "알약 아래는 통과")
        XCTAssertNil(layout(.collapsed).pill)
        XCTAssertNil(layout(.pinned).pill)
    }

    func testHiddenReceivesNothing() {
        XCTAssertEqual(layout(.hidden).zone(at: CGPoint(x: IslandLayout.panelWidth / 2, y: 10)), .none)
    }

    /// 펼치면 날개가 단어만큼 넓어지고 펼친 섬이 줄을 덮는다. 카메라 자리는 불변.
    func testOpenHeadWidensAndIslandCoversIt() {
        for nw in [185, 250] as [CGFloat] {
            let c = layout(.collapsed, notchWidth: nw), o = layout(.pinned, notchWidth: nw)
            XCTAssertGreaterThan(o.head.width, c.head.width)
            XCTAssertTrue(o.head.contains(c.head), "펼친 줄은 접힌 줄을 덮는다")
            XCTAssertEqual(o.head.minX + o.wings.left + nw / 2, IslandLayout.panelWidth / 2, accuracy: 0.001)
            XCTAssertTrue(o.island.contains(o.head))
            XCTAssertEqual(c.collapsedWidth, c.head.width, accuracy: 0.001)
        }
    }

    func testPanelFitsLargestCard() {
        XCTAssertGreaterThanOrEqual(IslandLayout.panelWidth, IslandLayout.cardWidth)
        XCTAssertGreaterThanOrEqual(IslandLayout.panelWidth, 250 + 2 * HeadSizing.rightBudget, "노치 250pt 에서도 펼친 줄이 패널 안")
    }
}

final class DigitScrambleTests: XCTestCase {
    /// 섞이는 중간 프레임에도 숫자 자리엔 숫자만, 다른 글자는 그대로 — `C%` 같은 글자가 나오면 안 된다
    func testIntermediateFramesOnlyContainDigitsInDigitSlots() {
        var seed = 7
        let rnd = { () -> Int in seed = (seed &* 1103515245 &+ 12345) & 0x7fffffff; return seed % 10 }
        for (old, target) in [("9%", "10%"), ("10%", "9%"), ("42%", "43%"), ("—", "9%"), ("9%", "—"), ("100%", "7%")] {
            for step in 0..<DigitScramble.steps {
                let f = DigitScramble.frame(old: old, target: target, step: step, random: rnd)
                XCTAssertEqual(f.count, target.count, "\(old)→\(target) step\(step): 길이 유지")
                for (a, b) in zip(f, target) {
                    if b.isNumber { XCTAssertTrue(a.isASCII && a.isNumber, "\(f) 의 숫자 자리에 글자가 들어감") }
                    else { XCTAssertEqual(a, b, "숫자가 아닌 자리는 그대로여야 한다: \(f)") }
                }
            }
        }
    }

    /// 해독이 끝나면 최종 값이 반드시 목표 그대로(숫자)다
    func testFinalFrameIsAlwaysTheTarget() {
        for target in ["9%", "10%", "100%", "0%", "—"] {
            XCTAssertEqual(DigitScramble.frame(old: "55%", target: target, step: DigitScramble.steps, random: { 3 }), target)
            XCTAssertEqual(DigitScramble.frame(old: "", target: target, step: 99, random: { 3 }), target)
        }
        // 안 바뀐 자리는 중간 프레임에서도 그대로
        XCTAssertEqual(DigitScramble.frame(old: "42%", target: "43%", step: 0, random: { 5 }), "45%")
    }
}


final class IslandMotionTests: XCTestCase {
    /// 닫힘이 충분히 빨리 끝난다(체감 ≈ 0.3~0.4초 안에 99%)
    func testCloseSettlesQuickly() {
        let p = IslandMotion.springProgress(t: 0.5, response: IslandMotion.closeResponse, damping: IslandMotion.closeDamping)
        XCTAssertGreaterThan(p, 0.99)
    }

    func testClampKeepsCollapsedFloor() {
        XCTAssertEqual(IslandMotion.clamped(500, min: 522), 522)
        XCTAssertEqual(IslandMotion.clamped(600, min: 522), 600)
    }
}

final class MemorySlotFlowTests: XCTestCase {
    /// 펼침 전환 시 배치 불변: 판정이 접힘 폭 기준이라 단어(펼침 폭)가 달라져도, 상태 전환 호출을 반복해도 결과가 같다.
    func testPlacementIsFixedByCollapsedWidthsAndIgnoresOpenWords() {
        // 링 없음 접힘: A. 펼침 폭으로 보면 B 가 더 균형적이지만(단어 때문) 판정은 접힘 기준이라 A 유지
        var f = MemorySlotFlow()
        let noRing = HeadContentWidths(cpuIcon: 14, cpuValue: 32, memIcon: 15, memValue: 24, glyph: 10, thermIcon: 10,
                                       memWord: 24, thermWord: 24, ring: 0, label: 0)
        for i in 0..<10 { XCTAssertEqual(f.update(widths: noRing, now: Double(i)), .right, "접힘 A 가 펼침에서도 유지") }
        // 링 있음 접힘: 동률 → B, 이후 단어 폭이 바뀌어도(펼침 판정이었다면 A 로 갈 수 있는 입력) 그대로 B
        var g = MemorySlotFlow()
        var ring = noRing; ring.ring = 16; ring.label = 46
        XCTAssertEqual(g.update(widths: ring, now: 0), .left)
        for i in 1..<10 { ring.memWord = 0; ring.thermWord = 60; XCTAssertEqual(g.update(widths: ring, now: Double(i)), .left) }
    }

    /// 안전장치만 예외: 펼침 기준 오른쪽이 예산을 넘으면 접힘 판정이 A 여도 B
    func testBudgetSafetyIsTheOnlyOpenStateException() {
        var f = MemorySlotFlow()
        var w = HeadContentWidths(cpuIcon: 14, cpuValue: 32, memIcon: 15, memValue: 24, glyph: 10, thermIcon: 10,
                                  memWord: 24, thermWord: 24, ring: 0, label: 0)
        XCTAssertEqual(f.update(widths: w, now: 0), .right)
        w.ring = 16; w.label = 300      // 긴 라벨: 접힘 폭엔 안 보이지만 펼침 폭이 예산 초과
        XCTAssertEqual(f.update(widths: w, now: 1), .left)
    }

    // 접힘 폭 예시: CPU 50, 메모리 56, 열 24, 링 16, 간격 10. 열+링 = 24+10+16 = 50
    private let cpu: CGFloat = 50, mem: CGFloat = 56, gap: CGFloat = 10, budget: CGFloat = 300

    /// rightNoMem: 메모리를 뺀 오른쪽 폭(링이 있으면 50, 없으면 24). 판정은 접힘 폭 기준.
    private func upd(_ f: inout MemorySlotFlow, rightNoMem: CGFloat, at t: Double, rightAOpen: CGFloat = 200) -> MemorySlotFlow.Side {
        f.update(cpuLeft: cpu, memory: mem, rightWithoutMemory: rightNoMem, gap: gap, rightAOpen: rightAOpen, budget: budget, now: t)
    }

    /// 링 없음: A(왼쪽 50 / 오른쪽 56+10+24=90, 차 40) vs B(왼쪽 116 / 오른쪽 24, 차 92) → A
    /// 동률 판정: 링 있는 전형적 접힘(CPU 50 / 메모리 56 / 열+링 50) → B
    func testTieGoesLeft() {
        var f = MemorySlotFlow()
        XCTAssertEqual(upd(&f, rightNoMem: 50, at: 0), .left)
    }

    func testNoRingStaysRight() {
        var f = MemorySlotFlow()
        for i in 0..<5 { XCTAssertEqual(upd(&f, rightNoMem: 24, at: Double(i)), .right) }
    }

    /// 링 있음(접힘): A(50 / 56+10+50=116, 차 66) vs B(116 / 50, 차 66) → 동률이면 B(실기 기대). 링이 더 커지면 당연히 B
    func testRingAppearsMovesLeftImmediately() {
        var f = MemorySlotFlow()
        XCTAssertEqual(upd(&f, rightNoMem: 24, at: 0), .right)
        // 링 + 라벨이 생겨 오른쪽(메모리 뺀)이 80: A(50/146, 차 96) vs B(116/80, 차 36) → B 즉시
        XCTAssertEqual(upd(&f, rightNoMem: 80, at: 0.1), .left)
    }

    func testTypicalCollapsedWithRingGoesLeft() {
        // 실기: `▣ 11% | ▤ 74% ◇ 🌡 ◇ ◔` — 접힘 CPU 50, 메모리 56, 열 24 + 링 16(+간격 10) = 50, 하지만 CPU 값 칸은 32 고정이라
        // 실제 CPU 칸이 더 작다. 폭을 넣어 확인: CPU 46, 메모리 56, 열+링 50
        var f = MemorySlotFlow()
        let s = f.update(cpuLeft: 46, memory: 56, rightWithoutMemory: 50, gap: 10, rightAOpen: 200, budget: budget, now: 0)
        // A: 46 / 116 (차 70), B: 112 / 50 (차 62) → B
        XCTAssertEqual(s, .left)
    }

    func testRingDisappearsReturnsRightOnlyAfterOneSecond() {
        var f = MemorySlotFlow()
        _ = upd(&f, rightNoMem: 80, at: 0)                       // B
        XCTAssertEqual(f.side, .left)
        XCTAssertEqual(upd(&f, rightNoMem: 24, at: 10.0), .left)   // A 가 더 균형적(차 40 vs 92, 마진 52 ≥ 16) — 1초 전엔 그대로
        XCTAssertEqual(upd(&f, rightNoMem: 24, at: 10.9), .left)
        XCTAssertEqual(upd(&f, rightNoMem: 24, at: 11.0), .right)
    }

    func testReturnNeedsMarginAndBrokenRoomRestartsTimer() {
        var f = MemorySlotFlow()
        _ = upd(&f, rightNoMem: 80, at: 0)
        // 차이가 거의 같으면(마진 < 16) 몇 초가 지나도 안 돌아온다: rightNoMem=50 → A 차 66 vs B 차 66, 마진 0
        for i in 1...10 { XCTAssertEqual(upd(&f, rightNoMem: 50, at: Double(i)), .left) }
        _ = upd(&f, rightNoMem: 24, at: 20.0)
        _ = upd(&f, rightNoMem: 50, at: 20.6)                     // 끊김
        XCTAssertEqual(upd(&f, rightNoMem: 24, at: 21.2), .left)
        XCTAssertEqual(upd(&f, rightNoMem: 24, at: 22.2), .right)
    }

    /// 경계에서 왕복해도 이동은 한 번뿐 — 깜빡임 0
    func testBoundaryOscillationDoesNotFlicker() {
        var f = MemorySlotFlow()
        var changes = 0, last = f.side
        for i in 0..<200 {
            let n: CGFloat = (i % 2 == 0) ? 80 : 24             // 링 라벨이 켜졌다 꺼졌다
            let s = upd(&f, rightNoMem: n, at: Double(i) * 0.25)
            if s != last { changes += 1; last = s }
        }
        XCTAssertEqual(changes, 1, "B 로 한 번 간 뒤 1초 유지 조건을 못 채워 돌아오지 않는다")
    }

    /// 펼침 판정: 같은 규칙을 펼침 폭(단어 포함)으로 — 입력만 다르다
    func testOpenStateUsesOpenWidths() {
        var f = MemorySlotFlow()
        // 펼침: CPU 51, 메모리 87(단어 포함), 열 54 + 링 67 + 간격 18 = 139, 간격 18
        // A: 51 / 87+18+139=244 (차 193), B: 51+18+87=156 / 139 (차 17) → B
        XCTAssertEqual(f.update(cpuLeft: 51, memory: 87, rightWithoutMemory: 139, gap: 18, rightAOpen: 244, budget: budget, now: 0), .left)
    }

    func testBudgetOverflowSafetyStillMovesLeft() {
        var f = MemorySlotFlow()
        // 균형만 보면 A 지만 오른쪽(A) 펼침 폭이 예산 초과 → B
        XCTAssertEqual(f.update(cpuLeft: 300, memory: 10, rightWithoutMemory: 0, gap: 10, rightAOpen: 320, budget: budget, now: 0), .left)
        // 안전장치가 풀리고 A 가 충분히 더 균형적이면 1초 뒤 복귀
        _ = f.update(cpuLeft: 300, memory: 10, rightWithoutMemory: 0, gap: 10, rightAOpen: 100, budget: budget, now: 5)
        // A: 300/10 (차 290) vs B: 320/0 (차 320) → A 가 30 ≥ 16 더 균형적 → 1초 지속 후 복귀
        XCTAssertEqual(f.update(cpuLeft: 300, memory: 10, rightWithoutMemory: 0, gap: 10, rightAOpen: 100, budget: budget, now: 5.9), .left)
        XCTAssertEqual(f.update(cpuLeft: 300, memory: 10, rightWithoutMemory: 0, gap: 10, rightAOpen: 100, budget: budget, now: 6.1), .right)
    }
}

final class HeadSizingTests: XCTestCase {
    // 글리프·글자 폭(예시): CPU 14+32, 메모리 15+24, 모양 10, 온도계 10, 단어 24/24, 링 16 + 라벨 46
    private let w = HeadContentWidths(cpuIcon: 14, cpuValue: 32, memIcon: 15, memValue: 24, glyph: 10, thermIcon: 10,
                                      memWord: 24, thermWord: 24, ring: 16, label: 46)

    /// 확정한 간격 값 — 상수는 `HeadSpacing` 한 곳
    func testSpacingTokensAreTheAgreedValues() {
        let c = HeadSpacing.collapsed, o = HeadSpacing.open
        XCTAssertEqual([c.iconValue, c.valueGlyph, c.slotGap, c.wingPad], [5, 4, 14, 10], "접힘: 아이콘↔값 5 · 값↔모양 4 · 칸 사이 14 · 날개 여백 10")
        XCTAssertEqual([o.iconValue, o.valueGlyph, o.glyphWord, o.slotGap, o.wingPad], [5, 4, 5, 18, 14], "펼침: 5 · 4 · 모양↔단어 5 · 칸 사이 18 · 여백 14")
        XCTAssertEqual([c.ringGap, o.ringGap], [20, 24], "온도↔링 간격만 더 넓다(접힘 20 · 펼침 +6 = 24)")
        XCTAssertEqual(HeadSpacing.at(open: false), c); XCTAssertEqual(HeadSpacing.at(open: true), o)
        XCTAssertGreaterThan(o.slotGap, c.slotGap)
    }

    /// 접힘: 단어 자리 없이 토큰 간격으로만 — 실제 칸 폭을 손으로 합산해서 맞춘다
    func testCollapsedWidthsUseCollapsedTokens() {
        let s = HeadSpacing.collapsed
        XCTAssertEqual(HeadSizing.cpu(w, s), 14 + 5 + 32)
        XCTAssertEqual(HeadSizing.memory(w, s, open: false), 15 + 5 + 24 + 4 + 10)
        XCTAssertEqual(HeadSizing.thermal(w, s, open: false), 10 + 5 + 10)
        XCTAssertEqual(HeadSizing.ring(w, s, open: false), 16, "접힘엔 라벨 없음")
        // 오른쪽 = 메모리 58 + 14 + 열 25 + (온도↔링) 20 + 링 16 = 133 → 날개 10 + 133 + 10
        XCTAssertEqual(HeadSizing.rightContent(w, side: .right, open: false), 133)
        XCTAssertEqual(HeadSizing.wings(w, side: .right, open: false).right, 153)
        XCTAssertEqual(HeadSizing.wings(w, side: .right, open: false).left, 71)
    }

    /// 펼침: 칸 사이 18 · 여백 14, 칸마다 자기 단어(모양↔단어 5)만큼 벌어진다
    func testOpenWidthsUseOpenTokensAndWords() {
        let s = HeadSpacing.open
        let mem = 15 + 5 + 24 + 4 + 10 + (5 + 24), th = 10 + 5 + 10 + (5 + 24), ring = 16 + 5 + 46
        XCTAssertEqual(HeadSizing.memory(w, s, open: true), CGFloat(mem))
        XCTAssertEqual(HeadSizing.thermal(w, s, open: true), CGFloat(th))
        XCTAssertEqual(HeadSizing.ring(w, s, open: true), CGFloat(ring))
        XCTAssertEqual(HeadSizing.rightContent(w, side: .right, open: true), CGFloat(mem + th + ring) + 18 + 24)
        XCTAssertEqual(HeadSizing.wings(w, side: .right, open: true).right, 14 + CGFloat(mem + th + ring) + 18 + 24 + 14)
        XCTAssertGreaterThan(HeadSizing.wings(w, side: .right, open: true).right, HeadSizing.wings(w, side: .right, open: false).right)
    }

    /// 두 상태의 칸 사이 간격이 실제로 토큰이다: 칸 3개 합 + 간격 2개 = 내용 폭
    func testSlotGapsAreExactlyTheTokenInBothStates() {
        for open in [false, true] {
            let s = HeadSpacing.at(open: open)
            let sum = HeadSizing.memory(w, s, open: open) + HeadSizing.thermal(w, s, open: open) + HeadSizing.ring(w, s, open: open)
            XCTAssertEqual(HeadSizing.rightContent(w, side: .right, open: open) - sum, s.slotGap + s.ringGap, "open=\(open): 메모리↔열 = 칸 사이, 열↔링 = 링 간격")
        }
    }

    func testNoJobNoRingNoGapAndMemoryOnLeft() {
        var j = w; j.ring = 0; j.label = 0
        XCTAssertEqual(HeadSizing.rightContent(j, side: .right, open: false), 58 + 14 + 25, "링이 없으면 링 몫의 간격도 없다")
        let left = HeadSizing.leftContent(w, side: .left, open: false)
        XCTAssertEqual(left, (14 + 5 + 32) + 14 + 58)
        XCTAssertEqual(HeadSizing.rightContent(w, side: .left, open: false), 25 + 20 + 16)
        XCTAssertEqual(HeadSizing.wings(w, side: .left, open: false).left, 10 + left + 10, "날개 폭 = 각자 내용 폭")
    }

    func testOverflowRuleInputs() {
        var longJob = w; longJob.label = 250
        let needed = HeadSizing.rightOpenWithoutMemory(longJob) + HeadSpacing.open.slotGap + HeadSizing.memory(longJob, .open, open: true)
        XCTAssertGreaterThan(needed, HeadSizing.rightBudget, "긴 라벨이면 메모리 칸 이동 조건")
        let normal = HeadSizing.rightOpenWithoutMemory(w) + HeadSpacing.open.slotGap + HeadSizing.memory(w, .open, open: true)
        XCTAssertLessThan(normal, HeadSizing.rightBudget, "평소 충전 라벨은 예산 안")
    }
}
