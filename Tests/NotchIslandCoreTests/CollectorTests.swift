import XCTest
@testable import NotchIslandCore

// MARK: - CPU

final class CPUTests: XCTestCase {
    func testPerCoreAndOverallFromKnownTicks() {
        let prev = [CoreTicks(user: 100, system: 100, idle: 800, nice: 0), CoreTicks(user: 0, system: 0, idle: 1000, nice: 0)]
        let cur = [CoreTicks(user: 150, system: 150, idle: 900, nice: 0), CoreTicks(user: 0, system: 0, idle: 1100, nice: 0)]
        let per = CPUMath.perCoreUsage(prev: prev, cur: cur)
        XCTAssertEqual(per?[0] ?? -1, 0.5, accuracy: 1e-9)      // 코어0: (50+50)/(50+50+100)
        XCTAssertEqual(per?[1] ?? -1, 0.0, accuracy: 1e-9)      // 코어1: 놀았음
        // 전체: busy 100 / total 300
        XCTAssertEqual(CPUMath.overallPercent(prev: prev, cur: cur) ?? -1, 100.0 / 300.0 * 100, accuracy: 1e-9)
    }

    func testCounterWrapAroundIsHandled() {
        let prev = [CoreTicks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)]
        let cur = [CoreTicks(user: 10, system: 0, idle: 20, nice: 0)]    // user 가 20 늘고 랩, idle 20
        XCTAssertEqual(CPUMath.perCoreUsage(prev: prev, cur: cur)?[0] ?? -1, 0.5, accuracy: 1e-9)
    }

    func testNoElapsedTicksOrCoreCountChangeReturnsNil() {
        let a = [CoreTicks(user: 1, system: 1, idle: 1, nice: 1)]
        XCTAssertNil(CPUMath.perCoreUsage(prev: a, cur: a))
        XCTAssertNil(CPUMath.overallPercent(prev: a, cur: a))
        XCTAssertNil(CPUMath.perCoreUsage(prev: a, cur: a + a))
    }

    private struct ScriptedSource: CPUTickSource {
        let box: Box
        final class Box { var frames: [[CoreTicks]?]; init(_ f: [[CoreTicks]?]) { frames = f } }
        func readTicks() -> [CoreTicks]? { box.frames.isEmpty ? nil : box.frames.removeFirst() }
    }

    func testProviderFirstSampleIsBaselineThenOK() {
        let f1 = [CoreTicks(user: 0, system: 0, idle: 100, nice: 0)]
        let f2 = [CoreTicks(user: 30, system: 20, idle: 150, nice: 0)]
        let p = CPUProvider(source: ScriptedSource(box: .init([f1, f2, nil])))
        let now = Date()
        XCTAssertEqual(p.sample(now: now).overall.status, .checking)
        let second = p.sample(now: now).overall
        XCTAssertEqual(second.value ?? -1, 50, accuracy: 1e-9)
        guard case .failed = p.sample(now: now).overall.status else { return XCTFail("읽기 실패는 failed 여야 한다 (0% 로 위장 금지)") }
    }

    /// 실제 호스트 값: 범위·코어 수 검증
    func testRealHostValuesAreInRange() throws {
        let p = CPUProvider()
        _ = p.sample(now: Date())
        Thread.sleep(forTimeInterval: 0.4)
        let r = p.sample(now: Date())
        let overall = try XCTUnwrap(r.overall.value, "두 번째 샘플은 값이 있어야 한다")
        XCTAssertTrue((0...100).contains(overall), "overall \(overall)")
        let cores = try XCTUnwrap(r.cores.value).perCore
        XCTAssertEqual(cores.count, ProcessInfo.processInfo.processorCount)
        XCTAssertTrue(cores.allSatisfy { (0...1).contains($0) })
    }

    func testCoreTopologyAddsUpToCoreCount() {
        let t = CoreTopology.read()
        guard !t.groups.isEmpty else { return }       // Intel 등 perflevel 없는 기기
        XCTAssertEqual(t.groups.map(\.count).reduce(0, +), ProcessInfo.processInfo.processorCount)
    }
}

// MARK: - 열

final class ThermalTests: XCTestCase {
    private struct Fixed: ThermalSource { let s: ProcessInfo.ThermalState; func currentState() -> ProcessInfo.ThermalState { s } }

    func testMapping() {
        XCTAssertEqual(ThermalProvider.level(from: .nominal), .nominal)
        XCTAssertEqual(ThermalProvider.level(from: .fair), .fair)
        XCTAssertEqual(ThermalProvider.level(from: .serious), .serious)
        XCTAssertEqual(ThermalProvider.level(from: .critical), .critical)
        XCTAssertEqual(ThermalLevel.serious.label, "높음")
        XCTAssertEqual(ThermalProvider(source: Fixed(s: .serious)).sample(now: Date()).value, .serious)
    }

    func testRealStateIsOneOfFour() {
        let r = ThermalProvider().sample(now: Date())
        XCTAssertEqual(r.status, .ok)
        XCTAssertNotNil(r.value)
    }
}

// MARK: - 메모리 압박

final class MemoryPressureTests: XCTestCase {
    private struct Probe: MemoryPressureProbe { let level: MemoryPressureLevel?; func read() -> MemoryPressureLevel? { level } }

    func testFirstSampleIsCheckingEvenIfProbeSaysNormal() {
        let p = MemoryPressureProvider(probe: Probe(level: .normal))
        let first = p.sample(now: Date())
        XCTAssertEqual(first.status, .checking, "시작 직후 이벤트가 없다고 정상으로 확정하면 안 된다")
        XCTAssertNil(first.value)
    }

    func testBaselineProbeThenEventWins() {
        let p = MemoryPressureProvider(probe: Probe(level: .normal))
        _ = p.sample(now: Date())
        let second = p.sample(now: Date())
        XCTAssertEqual(second.value, .normal)
        XCTAssertTrue(second.source.contains("초기값"))
        p.ingest(event: .warning)
        XCTAssertEqual(p.sample(now: Date()).value, .warning)
        p.ingest(event: .critical)
        XCTAssertEqual(p.sample(now: Date()).value, .critical)
        p.ingest(event: .normal)
        let back = p.sample(now: Date())
        XCTAssertEqual(back.value, .normal)
        XCTAssertFalse(back.source.contains("초기값"))
    }

    func testProbeFailureStaysChecking() {
        let p = MemoryPressureProvider(probe: Probe(level: nil))
        _ = p.sample(now: Date())
        XCTAssertEqual(p.sample(now: Date()).status, .checking)
    }

    /// 가짜 vm_statistics 로: 앱(internal−purgeable)+와이어드+압축만 센다. 파일 백업(external)·free 는 안 센다.
    func testUsedMemoryMatchesActivityMonitorDefinition() {
        var s = vm_statistics64()
        s.internal_page_count = 1_000_000
        s.purgeable_count = 200_000
        s.wire_count = 300_000
        s.compressor_page_count = 150_000
        s.external_page_count = 9_000_000          // 파일 캐시 — 무시돼야 한다
        s.free_count = 5_000_000
        s.active_count = 7_000_000
        let page: UInt64 = 16_384
        XCTAssertEqual(MemoryMath.usedBytes(from: s, pageSize: page), (800_000 + 300_000 + 150_000) * page)
        // 캐시가 아무리 늘어도 값이 안 바뀐다
        s.external_page_count = 1
        XCTAssertEqual(MemoryMath.usedBytes(from: s, pageSize: page), (800_000 + 300_000 + 150_000) * page)
    }

    func testPercentAndGBUnits() {
        let gb = UInt64(MemoryMath.bytesPerGB)
        let u = MemoryUsage(usedBytes: 79 * gb, totalBytes: 128 * gb)
        XCTAssertEqual(MemoryMath.percent(u), 61.71875, accuracy: 1e-9)           // 62% 로 표시
        XCTAssertEqual(Double(u.usedBytes) / MemoryMath.bytesPerGB, 79, accuracy: 1e-9)
        XCTAssertEqual(MemoryMath.percent(MemoryUsage(usedBytes: 5, totalBytes: 0)), 0, "분모 0 방어")
        XCTAssertEqual(MemoryMath.percent(MemoryUsage(usedBytes: 300, totalBytes: 100)), 100, "상한 100")
    }

    func testRealUsageIsSane() throws {
        let r = MemoryUsageProvider().sample(now: Date())
        let u = try XCTUnwrap(r.value)
        XCTAssertGreaterThan(u.usedBytes, 100_000_000)
        XCTAssertLessThanOrEqual(u.usedBytes, u.totalBytes)
        XCTAssertEqual(u.totalBytes, ProcessInfo.processInfo.physicalMemory)
    }

    func testRealPressureSysctlIsValid() {
        let p = SysctlMemoryPressureProbe().read()
        XCTAssertNotNil(p, "kern.memorystatus_vm_pressure_level 을 읽을 수 있어야 한다")
    }
}

// MARK: - 네트워크

final class NetworkTests: XCTestCase {
    private func c(_ rx: UInt64, _ tx: UInt64) -> InterfaceCounters { InterfaceCounters(rx: rx, tx: tx) }
    private let s: UInt64 = 1_000_000_000

    func testRateIsByteDeltaOverElapsed() throws {
        var calc = NetworkRateCalculator()
        XCTAssertNil(calc.update(counters: ["en0": c(1000, 500)], nowNs: 10 * s), "첫 샘플은 기준점만")
        let r = try XCTUnwrap(calc.update(counters: ["en0": c(1000 + 4000, 500 + 1000)], nowNs: 12 * s))
        XCTAssertEqual(r.downBytesPerSec, 2000, accuracy: 1e-6)
        XCTAssertEqual(r.upBytesPerSec, 500, accuracy: 1e-6)
    }

    func testSleepWakeFirstSampleIsBaselineOnly() throws {
        var calc = NetworkRateCalculator()
        _ = calc.update(counters: ["en0": c(0, 0)], nowNs: 0)
        _ = try XCTUnwrap(calc.update(counters: ["en0": c(2000, 0)], nowNs: 2 * s))
        // 1시간 잠자기: 카운터는 크게 늘었지만 급등으로 보여주면 안 된다
        XCTAssertNil(calc.update(counters: ["en0": c(900_000_000, 0)], nowNs: 3600 * s))
        // 다음 샘플은 방금 기준점 대비로 정상 계산
        let r = try XCTUnwrap(calc.update(counters: ["en0": c(900_000_000 + 6000, 0)], nowNs: 3602 * s))
        XCTAssertEqual(r.downBytesPerSec, 3000, accuracy: 1e-6)
    }

    func testCounterResetAndNewInterfaceAreSkipped() throws {
        var calc = NetworkRateCalculator()
        _ = calc.update(counters: ["en0": c(5000, 5000), "en1": c(100, 100)], nowNs: 0)
        // en0 카운터가 줄었음(리셋) → 건너뜀, en1 정상, en5 는 처음 보임 → 기준점만
        let r = try XCTUnwrap(calc.update(counters: ["en0": c(10, 10), "en1": c(300, 100), "en5": c(9_999_999, 9_999_999)], nowNs: 2 * s))
        XCTAssertEqual(r.downBytesPerSec, 100, accuracy: 1e-6)
        XCTAssertEqual(r.upBytesPerSec, 0, accuracy: 1e-6)
        // 모든 인터페이스가 리셋이면 값을 만들지 않는다
        var only = NetworkRateCalculator()
        _ = only.update(counters: ["en0": c(5000, 5000)], nowNs: 0)
        XCTAssertNil(only.update(counters: ["en0": c(1, 1)], nowNs: 2 * s))
    }

    func testResetDropsBaseline() {
        var calc = NetworkRateCalculator()
        _ = calc.update(counters: ["en0": c(0, 0)], nowNs: 0)
        calc.reset()
        XCTAssertNil(calc.update(counters: ["en0": c(10_000_000, 0)], nowNs: 2 * s))
    }

    func testRealCountersAreMonotonicAndRateNonNegative() throws {
        let src = GetIfAddrsCounterSource()
        let a = try XCTUnwrap(src.readCounters())
        XCTAssertFalse(a.keys.contains { $0.hasPrefix("lo") || $0.hasPrefix("utun") }, "루프백·VPN 은 합산하지 않는다")
        var calc = NetworkRateCalculator()
        _ = calc.update(counters: a, nowNs: MonotonicClock.nowNs())
        Thread.sleep(forTimeInterval: 1.1)
        let b = try XCTUnwrap(src.readCounters())
        if let r = calc.update(counters: b, nowNs: MonotonicClock.nowNs()) {
            XCTAssertGreaterThanOrEqual(r.downBytesPerSec, 0)
            XCTAssertGreaterThanOrEqual(r.upBytesPerSec, 0)
            XCTAssertLessThan(r.downBytesPerSec, 5_000_000_000, "물리적으로 불가능한 급등")
        }
    }
}

// MARK: - 디스크 · 배터리

final class DiskBatteryTests: XCTestCase {
    func testRealDiskRange() throws {
        let r = DiskProvider().sample(now: Date())
        let d = try XCTUnwrap(r.value)
        XCTAssertGreaterThan(d.freeBytes, 0)
        XCTAssertLessThanOrEqual(d.freeBytes, d.totalBytes)
        XCTAssertGreaterThan(d.totalBytes, 10_000_000_000)
        XCTAssertLessThan(d.freeGB, 100_000)
    }

    func testBatteryParserHandlesChargingAndNonBattery() {
        let d: [String: Any] = ["Type": "InternalBattery", "Current Capacity": 62, "Max Capacity": 100, "Is Charging": true, "Power Source State": "AC Power"]
        let b = BatteryParser.parse(d)
        XCTAssertEqual(b, BatteryInfo(percent: 62, isCharging: true, onACPower: true))
        XCTAssertNil(BatteryParser.parse(["Type": "UPS", "Current Capacity": 50, "Max Capacity": 100]))
        XCTAssertNil(BatteryParser.parse(["Type": "InternalBattery", "Current Capacity": 50, "Max Capacity": 0]))
    }

    private struct NoBattery: BatterySource { func read() -> BatteryInfo? { nil } }
    func testNoBatteryIsUnsupportedNotZero() {
        let r = BatteryProvider(source: NoBattery()).sample(now: Date())
        guard case .unsupported = r.status else { return XCTFail("배터리 없는 Mac 은 0% 가 아니라 지원 안 함") }
        XCTAssertNil(r.value)
    }
}

// MARK: - 프로세스

final class ProcessTests: XCTestCase {
    func testTopUsageMathAggregatesByNameAndSkipsNewPids() {
        let prev: [Int32: UInt64] = [1: 0, 2: 0, 3: 0]
        let cur = [
            ProcessSample(pid: 1, name: "App", cpuTimeNs: 2_000_000_000, residentBytes: 100),   // 2s/2s = 100%
            ProcessSample(pid: 2, name: "App", cpuTimeNs: 1_000_000_000, residentBytes: 50),    // +50%
            ProcessSample(pid: 3, name: "Other", cpuTimeNs: 200_000_000, residentBytes: 10),    // 10%
            ProcessSample(pid: 9, name: "New", cpuTimeNs: 9_000_000_000, residentBytes: 1),     // 새 pid: 기준점만
        ]
        let top = ProcessMath.topUsage(prev: prev, cur: cur, dtSeconds: 2, limit: 5)
        XCTAssertEqual(top.map(\.name), ["App", "Other"])
        XCTAssertEqual(top[0].cpuPercent, 150, accuracy: 1e-9)
        XCTAssertEqual(top[0].count, 2)
        XCTAssertEqual(top[0].residentBytes, 150)
    }

    func testPidReuseWithSmallerCounterIsSkipped() {
        let top = ProcessMath.topUsage(prev: [1: 5_000_000_000], cur: [ProcessSample(pid: 1, name: "X", cpuTimeNs: 1, residentBytes: 1)], dtSeconds: 1, limit: 3)
        XCTAssertTrue(top.isEmpty)
    }

    /// 실제 libproc 값 검증(mach 시간 단위 변환 포함): 코어 하나를 도는 `yes` 가 ~100% 로 읽혀야 한다.
    func testRealLibprocSeesBusyChild() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        child.standardOutput = FileHandle.nullDevice
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        let p = ProcessProvider()
        _ = p.sample(now: Date())
        Thread.sleep(forTimeInterval: 1.5)
        let r = p.sample(now: Date())
        let list = try XCTUnwrap(r.value)
        let yes = try XCTUnwrap(list.first { $0.name == "yes" }, "상위 5개에 yes 가 있어야 한다: \(list)")
        XCTAssertGreaterThan(yes.cpuPercent, 60)
        XCTAssertLessThan(yes.cpuPercent, 130)
    }
}

// MARK: - 기록 · 설정

final class HistoryAndSettingsTests: XCTestCase {
    func testHistoryCapsAtSixtyAndKeepsGaps() {
        var h = SampleHistory<Double>()
        for i in 0..<75 { h.append(Double(i)) }
        XCTAssertEqual(h.values.count, 60)
        XCTAssertEqual(h.values.first!, 15)
        h.append(nil)
        XCTAssertNil(h.values.last!)
    }

    func testDefaultsAndPersistence() {
        let suite = "notchisland.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let s = SettingsStore(defaults: d)
        XCTAssertTrue(s.hoverExpand); XCTAssertTrue(s.alertsEnabled); XCTAssertFalse(s.localModelEnabled)
        XCTAssertEqual(d.integer(forKey: "settingsVersion"), SettingsStore.currentVersion)
        s.hoverExpand = false; s.localModelEnabled = true
        let again = SettingsStore(defaults: d)
        XCTAssertFalse(again.hoverExpand); XCTAssertTrue(again.localModelEnabled)
    }

    /// v1 의 모드 값(귀여운·화려한·구 이름 포함)이 남아 있어도 읽히지 않고 지워진다 — 모드는 매트릭스 하나.
    func testLegacyThemeValuesAreDroppedOnMigration() {
        for old in ["cute", "fancy", "dev", "matrix"] {
            let suite = "notchisland.test.\(UUID().uuidString)"
            let d = UserDefaults(suiteName: suite)!
            defer { d.removePersistentDomain(forName: suite) }
            d.set(1, forKey: "settingsVersion"); d.set(old, forKey: "theme"); d.set(false, forKey: "hoverExpand")
            let s = SettingsStore(defaults: d)
            XCTAssertNil(d.object(forKey: "theme"), "\(old)")
            XCTAssertEqual(d.integer(forKey: "settingsVersion"), 2)
            XCTAssertFalse(s.hoverExpand, "다른 설정은 보존")
        }
    }
}
