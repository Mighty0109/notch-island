import XCTest
@testable import NotchIslandCore

final class FakeScheduler: Scheduler {
    private final class Item: Cancellable { var due: TimeInterval; var block: (() -> Void)?; init(_ d: TimeInterval, _ b: @escaping () -> Void) { due = d; block = b }; func cancel() { block = nil } }
    private var items: [Item] = []
    private(set) var now: TimeInterval = 0
    private(set) var scheduleCalls = 0           // 타이머를 새로 만든 횟수(같은 입력 반복에 일이 늘지 않는지 보는 용도)
    func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) -> Cancellable {
        scheduleCalls += 1
        let i = Item(now + seconds, block); items.append(i); return i
    }
    /// 시간을 흘리며 만기된 블록을 순서대로 실행
    func advance(_ ms: Int) {
        let target = now + Double(ms) / 1000
        while let next = items.filter({ $0.block != nil && $0.due <= target + 1e-9 }).min(by: { $0.due < $1.due }) {
            now = max(now, next.due)
            let b = next.block; next.block = nil
            b?()
        }
        now = target
    }
}

final class StateMachineTests: XCTestCase {
    var clock: FakeScheduler!
    var sm: IslandStateMachine!
    var log: [IslandPhase] = []

    override func setUp() {
        clock = FakeScheduler()
        sm = IslandStateMachine(scheduler: clock)
        log = []
        sm.onPhaseChange = { [unowned self] _, to in log.append(to) }
    }

    func testHoverOpensPreviewAtExactly300ms() {
        sm.pointerMoved(.head)
        clock.advance(299)
        XCTAssertEqual(sm.phase, .collapsed)
        clock.advance(1)
        XCTAssertEqual(sm.phase, .preview)
    }

    func testLeaveCollapsesPreviewAtExactly350ms() {
        sm.pointerMoved(.head); clock.advance(300)
        sm.pointerMoved(.none)
        clock.advance(349)
        XCTAssertEqual(sm.phase, .preview)
        clock.advance(1)
        XCTAssertEqual(sm.phase, .collapsed)
    }

    func testReenteringWithinLeaveDelayKeepsPreview() {
        sm.pointerMoved(.head); clock.advance(300)
        sm.pointerMoved(.none); clock.advance(200)
        sm.pointerMoved(.card); clock.advance(1000)
        XCTAssertEqual(sm.phase, .preview)
    }

    func testBriefPassOverDoesNotOpen() {
        sm.pointerMoved(.head); clock.advance(200)
        sm.pointerMoved(.none); clock.advance(2000)
        XCTAssertEqual(sm.phase, .collapsed)
    }

    // MARK: 성능 회귀 — 같은 구역 이벤트가 반복돼도 상태·타이머가 늘지 않는다 (실측: 마우스 이벤트마다 도는 경로)

    func testRepeatedSameZoneEventsScheduleOneHoverTimerAndChangeNothing() {
        for _ in 0..<500 { sm.pointerMoved(.head) }
        XCTAssertEqual(clock.scheduleCalls, 1, "섬 위에서 이벤트가 500번 와도 호버 타이머는 한 번만")
        XCTAssertTrue(log.isEmpty, "300ms 전엔 상태 전이 없음")
        clock.advance(300)
        XCTAssertEqual(log, [.preview])
        for _ in 0..<500 { sm.pointerMoved(.head); sm.pointerMoved(.card) }
        clock.advance(5000)
        XCTAssertEqual(log, [.preview], "펼친 뒤 같은 구역(섬 안)에서 이벤트가 반복돼도 전이 0회")
        XCTAssertEqual(clock.scheduleCalls, 1, "새 타이머도 0개")
    }

    func testRepeatedOutsideEventsDoNothing() {
        for _ in 0..<500 { sm.pointerMoved(.none) }
        clock.advance(5000)
        XCTAssertEqual(clock.scheduleCalls, 0, "먼 곳 이동은 타이머도 안 만든다")
        XCTAssertTrue(log.isEmpty)
        XCTAssertEqual(sm.phase, .collapsed)
    }

    func testRepeatedSameZoneWithHoverDisabledSchedulesNothing() {
        sm.hoverEnabled = false
        for _ in 0..<500 { sm.pointerMoved(.head) }
        clock.advance(5000)
        XCTAssertEqual(clock.scheduleCalls, 0)
        XCTAssertTrue(log.isEmpty)
    }

    func testClickPinsAndPinSurvivesLeave() {
        sm.pointerMoved(.head); clock.advance(300)
        sm.click(.card)
        XCTAssertEqual(sm.phase, .pinned)
        sm.pointerMoved(.none); clock.advance(5000)
        XCTAssertEqual(sm.phase, .pinned, "고정은 이탈로 접히지 않는다")
        sm.close()
        XCTAssertEqual(sm.phase, .collapsed)
    }

    func testHeadClickTogglesPin() {
        sm.click(.head); XCTAssertEqual(sm.phase, .pinned)
        sm.click(.head); XCTAssertEqual(sm.phase, .collapsed)
    }

    func testHoverDisabledNeverPreviewsButClickWorks() {
        sm.hoverEnabled = false
        sm.pointerMoved(.head); clock.advance(3000)
        XCTAssertEqual(sm.phase, .collapsed)
        sm.click(.head)
        XCTAssertEqual(sm.phase, .pinned)
    }

    func testAlertShowsThreeSecondsAfterPillFormed() {
        XCTAssertTrue(sm.beginAlert())
        XCTAssertEqual(sm.phase, .alert)
        clock.advance(780)                       // 방울이 떨어지는 동안은 시간을 세지 않는다
        XCTAssertEqual(sm.phase, .alert)
        sm.alertPillFormed()
        clock.advance(2999)
        XCTAssertEqual(sm.phase, .alert)
        clock.advance(1)
        XCTAssertEqual(sm.phase, .collapsed)
    }

    func testHoverOnPillHoldsAlertThenCollapses350AfterLeave() {
        sm.beginAlert(); sm.alertPillFormed()
        sm.pointerMoved(.pill)
        clock.advance(10_000)
        XCTAssertEqual(sm.phase, .alert, "호버 중에는 유지")
        XCTAssertTrue(sm.alertExpired)
        sm.pointerMoved(.none)
        clock.advance(349); XCTAssertEqual(sm.phase, .alert)
        clock.advance(1); XCTAssertEqual(sm.phase, .collapsed)
    }

    func testPillHoverDoesNotOpenPreview() {
        sm.beginAlert(); sm.alertPillFormed()
        sm.pointerMoved(.pill)
        clock.advance(1000)
        XCTAssertEqual(sm.phase, .alert)
    }

    func testClickOnPillPins() {
        sm.beginAlert(); sm.alertPillFormed()
        sm.click(.pill)
        XCTAssertEqual(sm.phase, .pinned)
    }

    func testAlertWhilePinnedOrPreviewDoesNotDropBubble() {
        sm.click(.head)
        XCTAssertFalse(sm.beginAlert(), "고정 중 알림은 카드 사건 줄만 갱신, 방울 없음")
        XCTAssertEqual(sm.phase, .pinned)
    }

    func testSecondAlertRestartsTimer() {
        sm.beginAlert(); sm.alertPillFormed()
        clock.advance(2000)
        XCTAssertTrue(sm.beginAlert()); sm.alertPillFormed()
        clock.advance(2000)
        XCTAssertEqual(sm.phase, .alert)
        clock.advance(1000)
        XCTAssertEqual(sm.phase, .collapsed)
    }

    func testHiddenIgnoresEverythingAndRestoresToCollapsed() {
        sm.setHidden(true)
        sm.pointerMoved(.head); clock.advance(1000); sm.click(.head)
        XCTAssertEqual(sm.phase, .hidden)
        XCTAssertFalse(sm.beginAlert())
        sm.setHidden(false)
        XCTAssertEqual(sm.phase, .collapsed)
    }

    func testHidingWhilePinnedCollapsesAfterRestore() {
        sm.click(.head); XCTAssertEqual(sm.phase, .pinned)
        sm.setHidden(true); sm.setHidden(false)
        XCTAssertEqual(sm.phase, .collapsed, "전체화면 복귀 뒤 오래된 고정 카드를 되살리지 않는다")
    }

    /// 빠른 이탈: 카드 위(안)에 있다가 중간 이벤트 없이 곧장 밖으로 — 이탈 후 350ms 안에 접혀야 한다
    func testFastExitWithoutIntermediateEventsCollapsesWithinLeaveDelay() {
        sm.pointerMoved(.head); clock.advance(300)
        XCTAssertEqual(sm.phase, .preview)
        sm.pointerMoved(.card); clock.advance(100)
        sm.pointerMoved(.none)                       // 한 번에 멀리 — 사이 이벤트 없음
        clock.advance(349); XCTAssertEqual(sm.phase, .preview)
        clock.advance(1); XCTAssertEqual(sm.phase, .collapsed)
    }

    /// 이탈 이벤트가 하나도 안 와도(누락) 주기 재평가가 같은 `.none` 을 넣으면 접힌다 — 10Hz 재평가의 전제
    func testRepeatedNoneEvaluationsAreHarmlessAndStillCollapse() {
        sm.pointerMoved(.head); clock.advance(300)
        for _ in 0..<6 { sm.pointerMoved(.none); clock.advance(60) }      // 총 360ms > 350     // 반복 재평가가 타이머를 계속 밀어내면 안 된다
        XCTAssertEqual(sm.phase, .collapsed)
    }

    /// 안에 있는 동안의 반복 재평가는 호버 타이머·상태를 흔들지 않는다
    func testRepeatedInsideEvaluationsDoNotDisturb() {
        sm.pointerMoved(.head)
        for _ in 0..<4 { clock.advance(90); sm.pointerMoved(.head) }      // 총 360ms ≥ 300
        XCTAssertEqual(sm.phase, .preview)       // 첫 진입 기준 300ms 에 열림 (재평가가 타이머를 리셋하지 않음)
    }

    // MARK: 실기 결함(미리보기에서 빨리 빠져나가도 안 접힘) — 시간 스윕

    /// preview 진입 후 0~600ms 사이 임의 시점(10ms 간격)에 이탈 → leaveDelay(350ms) 후 반드시 collapsed.
    /// `pings` > 0 이면 그 주기(ms)로 `setHidden(false)` 를 계속 호출한다 — 앱의 전체화면 감시(2초 주기 + 앱 전환 알림)가 하는 일.
    private func sweep(exitAfterPreviewMs d: Int, pingEveryMs pings: Int) -> IslandPhase {
        let c = FakeScheduler(); let m = IslandStateMachine(scheduler: c)
        func run(_ ms: Int) { // 핑을 섞어 시간을 흘린다
            var left = ms
            while left > 0 { let step = pings > 0 ? min(left, pings) : left; c.advance(step); left -= step; if pings > 0 { m.setHidden(false) } }
        }
        m.pointerMoved(.head); run(300)                 // preview
        XCTAssertEqual(m.phase, .preview)
        run(d)
        m.pointerMoved(.none)                            // 이탈
        run(350)
        return m.phase
    }

    func testExitAtAnyMomentAfterPreviewAlwaysCollapses() {
        for d in stride(from: 0, through: 600, by: 10) {
            XCTAssertEqual(sweep(exitAfterPreviewMs: d, pingEveryMs: 0), .collapsed, "이탈 \(d)ms 후")
        }
    }

    /// 같은 스윕에 setHidden(false) 핑(전체화면 감시)을 섞어도 접혀야 한다 — 핑이 leaveTimer 를 지우던 결함의 회귀 테스트
    func testExitSweepWithFullscreenWatcherPingsStillCollapses() {
        for ping in [30, 50, 70, 100, 130] {
            for d in stride(from: 0, through: 600, by: 10) {
                XCTAssertEqual(sweep(exitAfterPreviewMs: d, pingEveryMs: ping), .collapsed, "핑 \(ping)ms · 이탈 \(d)ms 후")
            }
        }
    }

    /// 숨김 상태가 안 바뀌는 setHidden 호출은 진행 중인 타이머를 건드리지 않는다
    func testNoOpSetHiddenKeepsPendingTimers() {
        sm.pointerMoved(.head); clock.advance(100)
        sm.setHidden(false)                              // 호버 타이머 진행 중
        clock.advance(200); XCTAssertEqual(sm.phase, .preview)
        sm.pointerMoved(.none); clock.advance(100)
        sm.setHidden(false)                              // 이탈 타이머 진행 중
        clock.advance(250); XCTAssertEqual(sm.phase, .collapsed)
    }
}
