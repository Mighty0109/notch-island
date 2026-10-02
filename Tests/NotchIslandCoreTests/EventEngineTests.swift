import XCTest
@testable import NotchIslandCore

/// 기록 재생: 저장된 관측 흐름을 엔진에 그대로 넣고 "언제 무슨 알림이 났나"만 본다. 실제 부하는 만들지 않는다.
final class EventEngineReplayTests: XCTestCase {
    struct Fired: Equatable { var t: TimeInterval; var cause: AlertCause; var level: Int; var extra: Int }

    func replay(_ trace: [Observation], config: EngineConfig = EngineConfig()) -> [Fired] {
        var e = EventEngine(config: config)
        var out: [Fired] = []
        for o in trace {
            if let b = e.ingest(o) { out.append(Fired(t: o.time, cause: b.primary.cause, level: b.primary.level, extra: b.extraCount)) }
        }
        return out
    }

    private func series(from: TimeInterval, to: TimeInterval, step: TimeInterval = 1, memory: Int? = nil, thermal: Int? = nil, onAC: Bool? = nil) -> [Observation] {
        stride(from: from, through: to, by: step).map { Observation(time: $0, memory: memory, thermal: thermal, onAC: onAC) }
    }

    func testQuietTraceFiresNothing() {
        XCTAssertEqual(replay(series(from: 0, to: 600, memory: 0, thermal: 0, onAC: true)), [])
    }

    func testMemoryWarningNeedsFiveSecondsOfPersistence() {
        let f = replay(series(from: 0, to: 20, memory: 1))
        XCTAssertEqual(f, [Fired(t: 5, cause: .memory, level: 1, extra: 0)])
        let tooShort = series(from: 0, to: 3, memory: 1) + series(from: 4, to: 30, memory: 0)
        XCTAssertEqual(replay(tooShort), [], "5초 못 채운 경고는 인정하지 않는다")
    }

    func testBoundaryFlappingDoesNotSpam() {
        // 경계값 왕복: 3초 경고 / 3초 정상 반복 — 5초 지속을 못 채우므로 알림 0
        var trace: [Observation] = []
        for k in 0..<20 {
            let base = Double(k) * 6
            trace += series(from: base, to: base + 2, memory: 1)
            trace += series(from: base + 3, to: base + 5, memory: 0)
        }
        XCTAssertEqual(replay(trace), [])
    }

    func testCriticalFiresImmediatelyAndHighestLevelBypassesHold() {
        var o = Observation(time: 100, memory: 2)
        o.topApp = "ComfyUI 92GB"
        var e = EventEngine()
        let b = e.ingest(o)
        XCTAssertEqual(b?.primary.cause, .memory)
        XCTAssertEqual(b?.primary.text, "메모리 압박 높음 · 관찰된 사용 상위: ComfyUI 92GB")
    }

    func testSameCauseSuppressedForFiveMinutesUnlessWorse() {
        var trace = series(from: 0, to: 0, memory: 2)                    // t=0 알림
        trace += series(from: 1, to: 40, memory: 0)                       // 15초 뒤 회복 인정
        trace += series(from: 100, to: 100, memory: 2)                    // t=100 재발 → 억제
        trace += series(from: 101, to: 140, memory: 0)
        trace += series(from: 301, to: 301, memory: 2)                    // 5분 지남 → 다시 알림
        XCTAssertEqual(replay(trace), [Fired(t: 0, cause: .memory, level: 2, extra: 0), Fired(t: 301, cause: .memory, level: 2, extra: 0)])
    }

    func testEscalationWithinSuppressWindowIsStillAnnounced() {
        // 주의(5초 지속) → 5분 안에 높음으로 악화: 더 높은 단계라 통과
        let trace = series(from: 0, to: 10, memory: 1) + series(from: 11, to: 12, memory: 2)
        XCTAssertEqual(replay(trace), [Fired(t: 5, cause: .memory, level: 1, extra: 0), Fired(t: 11, cause: .memory, level: 2, extra: 0)])
    }

    func testRecoveryHysteresis() {
        var e = EventEngine()
        _ = e.ingest(Observation(time: 0, memory: 2))
        XCTAssertEqual(e.effectiveMemoryLevel, 2)
        _ = e.ingest(Observation(time: 1, memory: 0))
        _ = e.ingest(Observation(time: 14, memory: 0))
        XCTAssertEqual(e.effectiveMemoryLevel, 2, "회복은 15초 지속돼야 인정")
        _ = e.ingest(Observation(time: 16, memory: 0))
        XCTAssertEqual(e.effectiveMemoryLevel, 0)
        // 도중에 다시 나빠지면 회복 타이머가 리셋된다
        var e2 = EventEngine()
        _ = e2.ingest(Observation(time: 0, memory: 2))
        _ = e2.ingest(Observation(time: 1, memory: 0))
        _ = e2.ingest(Observation(time: 10, memory: 2))
        _ = e2.ingest(Observation(time: 11, memory: 0))
        _ = e2.ingest(Observation(time: 20, memory: 0))
        XCTAssertEqual(e2.effectiveMemoryLevel, 2)
    }

    func testThermalFairIsQuietSeriousFires() {
        XCTAssertEqual(replay(series(from: 0, to: 60, thermal: 1)), [], "열 주의(fair)는 알림 기준이 아니다")
        let f = replay(series(from: 0, to: 5, thermal: 0) + series(from: 6, to: 8, thermal: 2) + series(from: 9, to: 12, thermal: 3))
        XCTAssertEqual(f, [Fired(t: 6, cause: .thermal, level: 2, extra: 0), Fired(t: 9, cause: .thermal, level: 3, extra: 0)])
    }

    func testChargerConnectedFiresOnlyOnTransitionAndNotOnStartup() {
        XCTAssertEqual(replay(series(from: 0, to: 10, onAC: true)), [], "앱이 켜질 때 이미 꽂혀 있으면 알리지 않는다")
        let f = replay(series(from: 0, to: 4, onAC: false) + series(from: 5, to: 8, onAC: true) + series(from: 9, to: 12, onAC: false))
        XCTAssertEqual(f, [Fired(t: 5, cause: .charger, level: 0, extra: 0)], "연결 때만, 해제는 조용히")
    }

    func testChargerPlugUnplugSpamIsSuppressed() {
        var trace: [Observation] = []
        for k in 0..<6 {
            let b = Double(k) * 20
            trace += series(from: b, to: b + 4, onAC: false) + series(from: b + 5, to: b + 9, onAC: true)
        }
        XCTAssertEqual(replay(trace).count, 1, "5분 안 반복 꽂기는 한 번만")
    }

    func testPriorityBundlesSimultaneousEvents() {
        var e = EventEngine()
        _ = e.ingest(Observation(time: 0, onAC: false))
        let b = e.ingest(Observation(time: 1, memory: 2, thermal: 2, onAC: true, chargePercent: 40))
        XCTAssertEqual(b?.primary.cause, .memory, "같은 우선순위면 메모리 → 열 → 충전 순")
        XCTAssertEqual(b?.extraCount, 2)
        XCTAssertGreaterThan(b?.primary.priority ?? 0, 20, "충전 연결(10)보다 위")
    }

    func testResetDoesNotReplayStaleChargerEvent() {
        var e = EventEngine()
        _ = e.ingest(Observation(time: 0, onAC: false))
        e.reset()                                              // 잠자기 복귀
        XCTAssertNil(e.ingest(Observation(time: 5000, onAC: true)), "잠든 사이 일어난 충전기 연결을 뒤늦게 재생하지 않는다")
    }

    func testUnknownLevelsNeverAlert() {
        XCTAssertEqual(replay(series(from: 0, to: 100, memory: nil, thermal: nil)), [])
    }
}
