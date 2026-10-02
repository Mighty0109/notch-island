import XCTest
@testable import NotchIslandCore

/// 안 4: 타이핑 + 해독 시간 계산, 가타카나 해독(숫자 자리), 로그 스트림, 카드 폭.
final class RevealTimingTests: XCTestCase {
    func testLineStartsStaggerFrom70ms() {
        XCTAssertEqual(RevealTiming.lineStart(order: 0), 0.070, accuracy: 1e-9)
        XCTAssertEqual(RevealTiming.lineStart(order: 10), 0.070 + 10 * 0.009, accuracy: 1e-9)
    }

    func testRevealedCountStepsAndBounds() {
        XCTAssertEqual(RevealTiming.revealedCount(chars: 40, elapsed: 0), 0)
        XCTAssertEqual(RevealTiming.revealedCount(chars: 40, elapsed: -1), 0)
        XCTAssertEqual(RevealTiming.revealedCount(chars: 40, elapsed: .infinity), 40, "연출이 끝났으면(무한대) 전부")
        XCTAssertEqual(RevealTiming.revealedCount(chars: 0, elapsed: 5), 0)
        // 시안 3.4px/ms ÷ 7.2px 칸 = 초당 ≈472자: 50ms → 23자
        XCTAssertEqual(RevealTiming.revealedCount(chars: 40, elapsed: 0.05), 23)
        var prev = 0
        for i in 0...200 {
            let n = RevealTiming.revealedCount(chars: 40, elapsed: Double(i) / 1000)
            XCTAssertGreaterThanOrEqual(n, prev, "드러난 글자 수는 줄지 않는다"); XCTAssertLessThanOrEqual(n, 40)
            prev = n
        }
        XCTAssertEqual(prev, 40)
    }

    func testSettledLagsRevealedByExactlyTheLag() {
        for e in stride(from: 0.0, through: 0.5, by: 0.01) {
            let revealed = RevealTiming.revealedCount(chars: 40, elapsed: e)
            let settled = RevealTiming.settledCount(chars: 40, elapsed: e)
            XCTAssertLessThanOrEqual(settled, revealed, "굳은 글자가 드러난 글자보다 많을 수 없다")
            XCTAssertEqual(settled, RevealTiming.revealedCount(chars: 40, elapsed: e - RevealTiming.settleLag))
        }
        XCTAssertEqual(RevealTiming.settledCount(chars: 40, elapsed: 0.1), 0, "0.14초 전에는 아무것도 안 굳는다")
    }

    func testTypedAndSettledFlags() {
        XCTAssertFalse(RevealTiming.isTyped(chars: 40, elapsed: 0.05))
        XCTAssertTrue(RevealTiming.isTyped(chars: 40, elapsed: 0.2))
        XCTAssertTrue(RevealTiming.isTyped(chars: 40, elapsed: .infinity))
        let d = RevealTiming.settleDuration(chars: 40)
        XCTAssertFalse(RevealTiming.isSettled(chars: 40, elapsed: d - 0.02))
        XCTAssertTrue(RevealTiming.isSettled(chars: 40, elapsed: d + 0.02))
    }

    /// 가장 늦게 시작하는 줄(순번 38 — 상태줄)의 가장 긴 줄(80자)도 코드 비·시계가 끝나기 전에 굳는다 → 시계를 멈춰도 가타카나가 남지 않는다
    func testEveryLineSettlesBeforeTheClockStops() {
        for order in 0...38 {
            let end = RevealTiming.lineStart(order: order) + RevealTiming.settleDuration(chars: 80)
            XCTAssertLessThanOrEqual(end, RevealTiming.cardTotal, "순번 \(order) 줄이 \(end)초에 굳음")
        }
    }

    func testRuleProgressIsMonotoneFromZeroToOne() {
        XCTAssertEqual(RevealTiming.ruleProgress(elapsed: -0.1), 0)
        XCTAssertEqual(RevealTiming.ruleProgress(elapsed: 0), 0)
        XCTAssertEqual(RevealTiming.ruleProgress(elapsed: RevealTiming.ruleDuration), 1, accuracy: 1e-9)
        XCTAssertEqual(RevealTiming.ruleProgress(elapsed: .infinity), 1)
        var prev = 0.0
        for i in 0...40 { let p = RevealTiming.ruleProgress(elapsed: Double(i) / 100); XCTAssertGreaterThanOrEqual(p, prev); prev = p }
    }

    /// 알림 글리치: 0.2초 동안 40ms 마다 5단계, 그 밖엔 없다(글자는 정상 표시)
    func testGlitchLastsPointTwoSecondsInFiveSteps() {
        XCTAssertNil(RevealTiming.glitchStep(elapsed: -0.01))
        XCTAssertEqual(RevealTiming.glitchStep(elapsed: 0), 0)
        XCTAssertEqual(RevealTiming.glitchStep(elapsed: 0.045), 1)
        XCTAssertEqual(RevealTiming.glitchStep(elapsed: 0.199), 4)
        XCTAssertNil(RevealTiming.glitchStep(elapsed: 0.2))
        XCTAssertNil(RevealTiming.glitchStep(elapsed: .infinity))
    }

    func testPillTotalCoversTypingAndCaretLinger() {
        let t = RevealTiming.pillTotal(chars: 36)
        XCTAssertGreaterThan(t, RevealTiming.settleDuration(chars: 36, charsPerSecond: RevealTiming.pillCharsPerSecond))
        XCTAssertGreaterThanOrEqual(RevealTiming.pillTotal(chars: 0), RevealTiming.glitchDuration)
    }
}

final class GlyphScrambleTests: XCTestCase {
    func testAsciiBecomesHalfWidthKanaHangulBecomesFullWidthAndSymbolsStay() {
        for seed in 0..<50 {
            let a = GlyphScramble.char(for: "7", seed: seed), l = GlyphScramble.char(for: "G", seed: seed)
            XCTAssertFalse(a.isASCII, "숫자 자리 해독 중엔 가타카나"); XCTAssertFalse(l.isASCII)
            let h = GlyphScramble.char(for: "압", seed: seed)
            XCTAssertFalse(h.isASCII); XCTAssertFalse(GlyphScramble.isHangul(h), "한글 자리는 가타카나(폭 유지용 전각)")
        }
        for c in " ·%/:.()-—|█◇▁" as String { XCTAssertEqual(GlyphScramble.char(for: c, seed: 3), c, "기호·공백은 그대로: \(c)") }
        XCTAssertEqual(GlyphScramble.char(for: "a", seed: -5).isASCII, false, "음수 시드도 안전")
    }
}

final class KanaDecodeTests: XCTestCase {
    private func isKana(_ c: Character) -> Bool { !c.isASCII && (c.unicodeScalars.first.map { (0xFF66...0xFF9D).contains($0.value) || (0x30A0...0x30FF).contains($0.value) } ?? false) }

    /// 바뀐 숫자 자리만 가타카나가 되고, 앞자리부터 숫자로 굳고, 끝은 항상 목표 그대로
    func testChangedDigitsDecodeLeftToRight() {
        let old = "9%", target = "10%"
        XCTAssertEqual(DigitScramble.changedDigitSlots(old: old, target: target), [0, 1])
        XCTAssertEqual(DigitScramble.kanaSteps(old: old, target: target), 3)
        let f0 = Array(DigitScramble.kanaFrame(old: old, target: target, step: 0, seed: 1))
        XCTAssertTrue(isKana(f0[0]) && isKana(f0[1])); XCTAssertEqual(f0[2], "%")
        let f1 = Array(DigitScramble.kanaFrame(old: old, target: target, step: 1, seed: 1))
        XCTAssertEqual(f1[0], "1", "앞자리가 먼저 숫자로 굳는다"); XCTAssertTrue(isKana(f1[1]))
        XCTAssertEqual(DigitScramble.kanaFrame(old: old, target: target, step: 2, seed: 1), target)
        XCTAssertEqual(DigitScramble.kanaFrame(old: old, target: target, step: 99, seed: 1), target)
    }

    func testOnlyChangedDigitSlotsAreTouchedAndNeverLetters() {
        for (old, target) in [("42%", "43%"), ("—", "9%"), ("9%", "—"), ("100%", "7%"), ("55%", "55%"), ("", "24%")] {
            let n = DigitScramble.kanaSteps(old: old, target: target)
            let changed = Set(DigitScramble.changedDigitSlots(old: old, target: target))
            for step in 0..<max(n, 1) {
                let f = Array(DigitScramble.kanaFrame(old: old, target: target, step: step, seed: 9)), t = Array(target)
                XCTAssertEqual(f.count, t.count, "\(old)→\(target) 길이 유지")
                for i in t.indices {
                    if changed.contains(i) { XCTAssertTrue(f[i] == t[i] || isKana(f[i]), "\(old)→\(target)[\(i)] 숫자 자리엔 숫자 또는 가타카나만: \(f[i])") }
                    else { XCTAssertEqual(f[i], t[i], "\(old)→\(target)[\(i)] 안 바뀐 자리는 그대로") }
                }
            }
            XCTAssertEqual(DigitScramble.kanaFrame(old: old, target: target, step: n, seed: 9), target, "끝 프레임 = 목표")
        }
        XCTAssertEqual(DigitScramble.kanaSteps(old: "55%", target: "55%"), 0)
    }
}

final class StatusLogTests: XCTestCase {
    func testKeepsOnlyLastThreeLinesWithIncreasingIds() {
        var log = StatusLog()
        for i in 0..<5 { log.append(time: "00:00:0\(i)", level: .info, text: "l\(i)") }
        XCTAssertEqual(log.lines.map(\.text), ["l2", "l3", "l4"])
        XCTAssertEqual(log.lines.map(\.id), [2, 3, 4], "id 는 계속 증가 — 새 줄 판별에 쓴다")
    }

    func testComposerUsesOnlyRealValues() {
        let now = Date()
        var s = SystemSnapshot.empty(at: now)
        XCTAssertEqual(StatusLogComposer.info(step: 0, snapshot: s), "cpu 확인 중", "값이 없으면 가짜 숫자 대신 확인 중")
        XCTAssertEqual(StatusLogComposer.info(step: 1, snapshot: s), "mem 확인 중 · 압박 확인 중")
        XCTAssertEqual(StatusLogComposer.info(step: 2, snapshot: s), "thermal 확인 중")
        s.cpu = .ok(24, unit: "%", at: now, source: "t")
        s.topProcesses = .ok([ProcessUsage(name: "ComfyUI", cpuPercent: 339, residentBytes: 1, count: 1)], unit: "%", at: now, source: "t")
        s.memory = .ok(.normal, unit: "level", at: now, source: "t")
        s.memoryUsage = .ok(MemoryUsage(usedBytes: UInt64(93.3 * MemoryMath.bytesPerGB), totalBytes: UInt64(128 * MemoryMath.bytesPerGB)), unit: "bytes", at: now, source: "t")
        s.thermal = .ok(.nominal, unit: "level", at: now, source: "t")
        s.disk = .ok(DiskInfo(freeBytes: 106_000_000_000, totalBytes: 1, volumeName: "x"), unit: "bytes", at: now, source: "t")
        XCTAssertEqual(StatusLogComposer.info(step: 0, snapshot: s), "cpu 24% · 상위 ComfyUI")
        XCTAssertEqual(StatusLogComposer.info(step: 1, snapshot: s), "mem 93.3/128G · 압박 정상")
        XCTAssertEqual(StatusLogComposer.info(step: 2, snapshot: s), "thermal 보통 · disk 106G 남음")
        XCTAssertEqual(StatusLogComposer.info(step: 3, snapshot: s), StatusLogComposer.info(step: 0, snapshot: s), "3줄 주기로 돈다")
        XCTAssertEqual(StatusLogComposer.info(step: -1, snapshot: s), StatusLogComposer.info(step: 2, snapshot: s), "음수 단계도 안전")
    }
}

final class CardWidthTests: XCTestCase {
    /// 안 4 카드 폭 720. 카메라 중심 양쪽 360 이상은 늘 섬 안(머리줄이 좁아도 카드가 받쳐진다)
    func testCardIs720AndBothSidesCoverHalfCard() {
        XCTAssertEqual(IslandLayout.cardWidth, 720)
        for nw in [185, 250] as [CGFloat] {
            let l = IslandLayout(phase: .pinned, notchWidth: nw, notchHeight: 43)
            XCTAssertGreaterThanOrEqual(l.openExtents.left, 360); XCTAssertGreaterThanOrEqual(l.openExtents.right, 360)
            XCTAssertGreaterThanOrEqual(l.openWidth, 720)
            XCTAssertLessThanOrEqual(l.openWidth, IslandLayout.panelWidth)
        }
    }

    func testPillCornerIsNineNotCapsule() {
        XCTAssertEqual(IslandLayout.pillCorner, 9)
        XCTAssertLessThan(IslandLayout.pillCorner, IslandLayout.pillHeight / 2)
    }
}
