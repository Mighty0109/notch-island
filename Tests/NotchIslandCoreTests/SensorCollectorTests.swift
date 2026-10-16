import XCTest
@testable import NotchIslandCore

private final class CountingSensors: PrivateSensorProvider {
    var sampleTimes: [Date] = []
    var calls: Int { sampleTimes.count }
    func sample(now: Date) -> Reading<SensorValues> {
        sampleTimes.append(now)
        return .ok(SensorValues(cpuAverage: 70, fanRPMs: [5000]), unit: "°C", at: now, source: "fake")
    }
}

/// 센서는 펼침 동안만, 최대 2초에 한 번 읽는다. 센서 모듈이 없으면 미지원(칸 숨김).
final class SensorCollectorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 10_000)

    func testNotReadWhileCollapsed() {
        let fake = CountingSensors()
        let c = MetricsCollector(sensors: fake)
        for i in 0..<4 { _ = c.collectNow(now: t0.addingTimeInterval(Double(i) * 2)) }
        XCTAssertEqual(fake.calls, 0, "접힘 동안 SMC 를 읽지 않는다")
    }

    func testExpandedReadsAtMostOncePerTwoSeconds() {
        let fake = CountingSensors()
        let c = MetricsCollector(sensors: fake)
        c.setExpanded(true)
        var snaps: [SystemSnapshot] = []
        for i in 0..<6 { snaps.append(c.collectNow(now: t0.addingTimeInterval(Double(i)))) }      // 1초 간격 6틱
        XCTAssertEqual(fake.calls, 3, "t=0,2,4 만 읽는다")
        XCTAssertEqual(snaps[1].sensors.timestamp, snaps[0].sensors.timestamp, "건너뛴 틱은 직전 값을 그대로 쓴다")
        XCTAssertEqual(snaps[0].sensors.value?.cpuAverage, 70)
    }

    func testCollapsingDropsStaleValuesAndStopsReading() {
        let fake = CountingSensors()
        let c = MetricsCollector(sensors: fake)
        c.setExpanded(true)
        _ = c.collectNow(now: t0)
        c.setExpanded(false)
        let s = c.collectNow(now: t0.addingTimeInterval(5))
        XCTAssertEqual(fake.calls, 1)
        XCTAssertNil(s.sensors.value, "접힌 뒤 오래된 온도를 내보이지 않는다")
        c.setExpanded(true)
        _ = c.collectNow(now: t0.addingTimeInterval(5.1))
        XCTAssertEqual(fake.calls, 2, "다시 펼치면 바로 한 번 읽는다")
    }

    func testNoSensorModuleIsUnsupported() {
        let s = MetricsCollector().collectNow(now: t0)
        if case .unsupported = s.sensors.status {} else { XCTFail("센서 모듈 없음 = 미지원: \(s.sensors.status)") }
    }

    func testRapidReopeningKeepsThrottleAndDiscardsStaleValues() {
        let fake = CountingSensors()
        let c = MetricsCollector(sensors: fake)
        c.setExpanded(true)
        XCTAssertNotNil(c.collectNow(now: t0).sensors.value)

        // 같은 경계를 세 번 반복해도 접힘/재펼침이 조회 허용 시각을 초기화하지 않는다.
        for cycle in 0..<3 {
            let base = t0.addingTimeInterval(Double(cycle) * 2)
            let callsBefore = fake.calls
            for (close, reopen) in [(0.1, 0.2), (0.3, 0.4)] {
                c.setExpanded(false)
                let collapsed = c.collectNow(now: base.addingTimeInterval(close))
                XCTAssertNil(collapsed.sensors.value, "접힘 때 오래된 표시값 폐기")
                XCTAssertEqual(fake.calls, callsBefore, "접힌 동안 조회 0회")
                c.setExpanded(true)
                let reopened = c.collectNow(now: base.addingTimeInterval(reopen))
                XCTAssertNil(reopened.sensors.value, "2초 전에는 오래된 값을 다시 내보이지 않는다")
                if case .checking = reopened.sensors.status {} else { XCTFail("재조회 허용 전에는 확인 중") }
                XCTAssertEqual(fake.calls, callsBefore, "빠른 재펼침은 새 조회를 허용하지 않는다")
            }
            _ = c.collectNow(now: base.addingTimeInterval(1.9))
            XCTAssertEqual(fake.calls, callsBefore, "2.0초 전에는 최초 1회만 조회")
            XCTAssertNotNil(c.collectNow(now: base.addingTimeInterval(2)).sensors.value)
            XCTAssertEqual(fake.calls, callsBefore + 1, "정확히 2.0초에 다음 조회")
        }
        XCTAssertEqual(fake.sampleTimes, [0.0, 2, 4, 6].map { t0.addingTimeInterval($0) })
        for (earlier, later) in zip(fake.sampleTimes, fake.sampleTimes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.timeIntervalSince(earlier), 2)
        }
        print("SENSOR rapid reopen sample offsets = \(fake.sampleTimes.map { $0.timeIntervalSince(t0) })")
    }
}
