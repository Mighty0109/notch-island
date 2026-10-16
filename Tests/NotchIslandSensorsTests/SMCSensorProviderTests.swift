import XCTest
import NotchIslandCore
@testable import NotchIslandSensors

/// 가짜 SMC — 실기 무관. 키 열거 횟수를 센다.
final class FakeSMC: SMCSource {
    var values: [String: SMCValue]
    let order: [String]
    var failKeyIndexOnce: Int?
    private(set) var keyAtCalls = 0
    private(set) var keyCountCalls = 0
    private(set) var enumeratedKeys: [String] = []
    private(set) var readCalls: [String] = []

    init(_ values: [String: SMCValue], order: [String]? = nil) {
        self.values = values
        self.order = order ?? values.keys.sorted()
    }

    func keyCount() -> Int? { keyCountCalls += 1; return order.count }
    func key(at index: Int) -> String? {
        keyAtCalls += 1
        if failKeyIndexOnce == index { failKeyIndexOnce = nil; return nil }
        guard order.indices.contains(index) else { return nil }
        let key = order[index]
        enumeratedKeys.append(key)
        return key
    }
    func read(_ key: String) -> SMCValue? { readCalls.append(key); return values[key] }

    static func flt(_ v: Float) -> SMCValue {
        let r = v.bitPattern
        return SMCValue(type: "flt", bytes: [UInt8(r & 0xff), UInt8((r >> 8) & 0xff), UInt8((r >> 16) & 0xff), UInt8((r >> 24) & 0xff)])
    }
    static func ui8(_ v: UInt8) -> SMCValue { SMCValue(type: "ui8", bytes: [v]) }
}

final class SMCSensorProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func typical(overrides: [String: SMCValue] = [:]) -> FakeSMC {
        FakeSMC([
            "Tp01": FakeSMC.flt(60), "Tp02": FakeSMC.flt(80), "Tp03": FakeSMC.flt(70),
            "Tg01": FakeSMC.flt(50), "Tg02": FakeSMC.flt(70),
            "TB0T": FakeSMC.flt(31),
            "FNum": FakeSMC.ui8(2), "F0Ac": FakeSMC.flt(5000), "F1Ac": FakeSMC.flt(5300),
            "F0Mx": FakeSMC.flt(8000), "F1Mx": FakeSMC.flt(7000),
            "Ta00": FakeSMC.flt(99),                       // 집계 대상 아닌 키는 무시
        ].merging(overrides) { _, replacement in replacement })
    }

    func testDecodeFloatAndUInt8() {
        XCTAssertEqual(SMCDecode.number(FakeSMC.flt(70.5)), 70.5)
        XCTAssertEqual(SMCDecode.number(FakeSMC.ui8(2)), 2)
        XCTAssertNil(SMCDecode.number(SMCValue(type: "flt", bytes: [0, 0])), "바이트가 모자라면 nil")
        XCTAssertNil(SMCDecode.number(SMCValue(type: "hex_", bytes: [1, 2, 3, 4])), "모르는 타입은 nil")
        XCTAssertNil(SMCDecode.number(FakeSMC.flt(.nan)), "NaN 은 값이 아니다")
        XCTAssertEqual(SMCDecode.number(SMCValue(type: "ui16", bytes: [0x12, 0x34])), 0x1234)
        XCTAssertEqual(SMCDecode.number(SMCValue(type: "ui32", bytes: [0, 0, 0x0e, 0xba])), 3770)
    }

    func testAggregatesCpuAvgMaxGpuAvgBatteryAndFans() throws {
        let p = SMCSensorProvider { self.typical() }
        let r = p.sample(now: now)
        XCTAssertEqual(r.status, .ok)
        let v = try XCTUnwrap(r.value)
        XCTAssertEqual(try XCTUnwrap(v.cpuAverage), 70, accuracy: 0.001)
        XCTAssertEqual(v.cpuMax, 80)
        XCTAssertEqual(try XCTUnwrap(v.gpuAverage), 60, accuracy: 0.001)
        XCTAssertEqual(v.battery, 31)
        XCTAssertEqual(v.fanRPMs, [5000, 5300])
        XCTAssertEqual(v.fanMaxRPMs, [8000, 7000])
        XCTAssertEqual(v.fanPercent, 69)
    }

    func testDropsUnrealisticValues() throws {
        let smc = typical(overrides: [
            "Tp04": FakeSMC.flt(0),                      // 0 이하
            "Tp05": FakeSMC.flt(-12),
            "Tp06": FakeSMC.flt(131),                    // 130 초과
            "Tg03": FakeSMC.flt(900),
            "TB0T": FakeSMC.flt(0),
            "F1Ac": FakeSMC.flt(-300),                   // 음수 RPM
        ])
        let v = try XCTUnwrap(SMCSensorProvider { smc }.sample(now: now).value)
        for key in ["Tp04", "Tp05", "Tp06", "Tg03"] {
            let enumerations = smc.enumeratedKeys.filter { $0 == key }.count
            let reads = smc.readCalls.filter { $0 == key }.count
            XCTAssertEqual(enumerations, 1, "\(key)는 실제 열거돼야 한다")
            XCTAssertEqual(reads, 1, "\(key)는 필터 전에 실제 읽혀야 한다")
            print("SMC invalid temperature \(key): enumerated=\(enumerations), read=\(reads)")
        }
        XCTAssertEqual(try XCTUnwrap(v.cpuAverage), 70, accuracy: 0.001, "비현실 값은 평균에 안 들어간다")
        XCTAssertEqual(v.cpuMax, 80)
        XCTAssertEqual(try XCTUnwrap(v.gpuAverage), 60, accuracy: 0.001)
        XCTAssertNil(v.battery)
        XCTAssertEqual(v.fanRPMs, [5000, nil])
        XCTAssertEqual(v.fanMaxRPMs, [8000, 7000])
    }

    func testUnreadableFirstFanKeepsItsNumberAndSecondFanMaximum() throws {
        for current in [nil, FakeSMC.flt(-1), FakeSMC.flt(30001)] as [SMCValue?] {
            let smc = typical()
            smc.values["F0Ac"] = current
            let v = try XCTUnwrap(SMCSensorProvider { smc }.sample(now: now).value)
            XCTAssertEqual(v.fanRPMs, [nil, 5300])
            XCTAssertEqual(v.fanMaxRPMs, [8000, 7000])
            XCTAssertEqual(v.fanPercents, [nil, 5300.0 / 7000 * 100])
            XCTAssertEqual(v.fanPercent, 76)
        }
    }

    func testMissingOrInvalidMaximumDoesNotDiscardCurrentRPMOrTemperature() throws {
        let badMaxima: [SMCValue?] = [nil, FakeSMC.flt(0), FakeSMC.flt(-1), FakeSMC.flt(30001),
                                      FakeSMC.flt(.nan), FakeSMC.flt(.infinity), SMCValue(type: "hex_", bytes: [0])]
        for maximum in badMaxima {
            let smc = typical()
            smc.values["F0Mx"] = maximum
            let v = try XCTUnwrap(SMCSensorProvider { smc }.sample(now: now).value)
            XCTAssertEqual(v.fanRPMs, [5000, 5300])
            XCTAssertEqual(v.fanMaxRPMs, [nil, 7000])
            XCTAssertEqual(v.fanPercent, 76)
            XCTAssertEqual(v.cpuAverage, 70)
        }
        let smc = typical()
        smc.values["F0Mx"] = nil; smc.values["F1Mx"] = nil
        let v = try XCTUnwrap(SMCSensorProvider { smc }.sample(now: now).value)
        XCTAssertNil(v.fanPercent)
        XCTAssertEqual(v.fanRPMs.count, 2)
    }

    func testEveryValueUnrealisticIsFailedNotZero() {
        let smc = FakeSMC(["Tp01": FakeSMC.flt(0), "FNum": FakeSMC.ui8(1), "F0Ac": FakeSMC.flt(-1)])
        let r = SMCSensorProvider { smc }.sample(now: now)
        XCTAssertNil(r.value)
        if case .failed = r.status {} else { XCTFail("실패는 0 으로 위장하지 않는다: \(r.status)") }
    }

    func testKeyEnumerationHappensOnceAcrossManySamples() {
        let smc = typical()
        let p = SMCSensorProvider { smc }
        for _ in 0..<5 { _ = p.sample(now: now) }
        XCTAssertEqual(smc.keyCountCalls, 1)
        XCTAssertEqual(smc.keyAtCalls, smc.order.count, "키 목록 열거는 키 수만큼 1회")
        XCTAssertFalse(smc.readCalls.contains("Ta00"), "열거 뒤엔 필요한 키만 읽는다")
        // 샘플 1회당: Tp 3 + Tg 2 + TB0T 1 + F 2 = 8회 (FNum 은 시작 때 한 번)
        for key in ["FNum", "F0Mx", "F1Mx"] { XCTAssertEqual(smc.readCalls.filter { $0 == key }.count, 1, "\(key)는 시작 때 한 번") }
        let perSample = smc.readCalls.count - 3       // 시작의 FNum · 최고 RPM 2개
        XCTAssertEqual(perSample, 8 * 5)
    }

    func testIncompleteEnumerationFailsAndRetriesAtNextSample() throws {
        let values = ["Tp01": FakeSMC.flt(70), "Tp02": FakeSMC.flt(80), "Tg01": FakeSMC.flt(60)]
        for failedIndex in 0..<values.count {
            let smc = FakeSMC(values, order: ["Tp01", "Tp02", "Tg01"])
            smc.failKeyIndexOnce = failedIndex
            let provider = SMCSensorProvider { smc }
            let first = provider.sample(now: now)
            XCTAssertEqual(first.status, .failed("SMC 키 열거 실패 (index \(failedIndex))"))
            XCTAssertNil(first.value, "부분 계획은 값으로 내보내지 않는다")
            XCTAssertTrue(smc.readCalls.isEmpty, "열거가 끝나기 전에는 값을 읽지 않는다")

            let second = provider.sample(now: now.addingTimeInterval(2))
            XCTAssertEqual(second.status, .ok)
            XCTAssertEqual(second.timestamp.timeIntervalSince(first.timestamp), 2)
            let v = try XCTUnwrap(second.value)
            XCTAssertEqual(v.cpuAverage, 75)
            XCTAssertEqual(v.cpuMax, 80)
            XCTAssertEqual(v.gpuAverage, 60, "실패 index 뒤의 GPU 도 전체 계획에 들어간다")
            XCTAssertEqual(smc.keyCountCalls, 2)
            let expectedKeyCalls = failedIndex + 1 + values.count
            XCTAssertEqual(smc.keyAtCalls, expectedKeyCalls)

            XCTAssertEqual(provider.sample(now: now.addingTimeInterval(4)).status, .ok)
            XCTAssertEqual(smc.keyCountCalls, 2, "완성한 계획은 다시 열거하지 않는다")
            XCTAssertEqual(smc.keyAtCalls, expectedKeyCalls)
            print("SMC enumeration retry index=\(failedIndex): first=\(first.status), +2s=\(second.status), CPU=\(String(describing: v.cpuAverage)), GPU=\(String(describing: v.gpuAverage)), keyCountCalls=\(smc.keyCountCalls)")
        }
    }

    func testMaximumIsCachedWhileCurrentRPMIsResampled() throws {
        let smc = typical()
        let provider = SMCSensorProvider { smc }
        _ = provider.sample(now: now)
        smc.values["F0Mx"] = FakeSMC.flt(1)
        smc.values["F0Ac"] = FakeSMC.flt(0)
        let v = try XCTUnwrap(provider.sample(now: now.addingTimeInterval(2)).value)
        XCTAssertEqual(v.fanRPMs, [0, 5300])
        XCTAssertEqual(v.fanMaxRPMs, [8000, 7000])
    }

    func testNothingIsOpenedBeforeFirstSample() {
        var opened = 0
        let p = SMCSensorProvider { opened += 1; return nil }
        XCTAssertEqual(opened, 0, "접힌 동안엔 SMC 를 열지 않는다(첫 샘플 전엔 안 연다)")
        _ = p.sample(now: now); _ = p.sample(now: now)
        XCTAssertEqual(opened, 1, "열기 실패도 다시 시도하지 않는다")
    }

    func testUnsupportedWhenSMCCannotOpenOrHasNoSensorKeys() {
        if case .unsupported = SMCSensorProvider { nil }.sample(now: now).status {} else { XCTFail("못 열면 미지원") }
        let empty = FakeSMC(["Xx01": FakeSMC.flt(1)])
        if case .unsupported = SMCSensorProvider { empty }.sample(now: now).status {} else { XCTFail("센서 키가 하나도 없으면 미지원") }
    }

    func testFanlessMachineStillReportsTemperature() throws {
        let smc = FakeSMC(["Tp01": FakeSMC.flt(40), "FNum": FakeSMC.ui8(0)])
        let v = try XCTUnwrap(SMCSensorProvider { smc }.sample(now: now).value)
        XCTAssertEqual(v.fanRPMs, [])
        XCTAssertEqual(v.fanMaxRPMs, [])
        XCTAssertNil(v.fanPercent)
        XCTAssertEqual(v.cpuAverage, 40)
    }

    /// 쓰기 명령 부재 보증: 연결 계층의 SMC 명령 상수는 5 · 8 · 9 뿐 (소스 grep 은 RESULT 의 A5 참고)
    func testRealConnectionSourceHasOnlyReadCommands() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NotchIslandSensors/AppleSMCConnection.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        let cmds = src.split(separator: "\n").filter { $0.contains("private static let cmd") }
        XCTAssertEqual(cmds.count, 3)
        for (line, n) in zip(cmds, [5, 8, 9]) { XCTAssertTrue(line.hasSuffix("= \(n)"), "\(line)") }
    }
}

/// 실기 SMC 스모크 — `NOTCH_ISLAND_REAL_SMC=1` 일 때만. 읽기만 한다.
final class RealSMCSmokeTests: XCTestCase {
    func testRealSMCReadsTemperaturesAndFans() throws {
        guard ProcessInfo.processInfo.environment["NOTCH_ISLAND_REAL_SMC"] == "1" else { throw XCTSkip("NOTCH_ISLAND_REAL_SMC=1 일 때만 실행") }
        let p = SMCSensorProvider()
        let t0 = Date()
        let first = p.sample(now: t0)
        let firstMs = Date().timeIntervalSince(t0) * 1000
        let t1 = Date()
        let second = p.sample(now: t1)
        let secondMs = Date().timeIntervalSince(t1) * 1000
        print("REAL_SMC first=\(first.status) \(String(format: "%.1f", firstMs))ms value=\(String(describing: first.value))")
        print("REAL_SMC second=\(second.status) \(String(format: "%.1f", secondMs))ms value=\(String(describing: second.value))")
        XCTAssertEqual(first.status, .ok, "이 맥에서 SMC 를 읽을 수 있어야 한다: \(first.status)")
        let v = try XCTUnwrap(first.value)
        XCTAssertNotNil(v.cpuAverage); XCTAssertNotNil(v.gpuAverage)
        XCTAssertTrue((0.000_001...130).contains(v.cpuAverage ?? 0))
        XCTAssertFalse(v.fanRPMs.isEmpty)
        XCTAssertEqual(v.fanRPMs.count, v.fanMaxRPMs.count)
        for i in v.fanRPMs.indices {
            print("REAL_SMC fan\(i + 1) Ac=\(String(describing: v.fanRPMs[i])) Mx=\(String(describing: v.fanMaxRPMs[i])) percent=\(String(describing: v.fanPercents[i]))")
        }
        XCTAssertNotNil(v.fanPercent, "팬이 있으면 유효한 최고 RPM 이 하나 이상 있어야 한다")
        XCTAssertEqual(first.value?.fanMaxRPMs, second.value?.fanMaxRPMs)
    }
}
