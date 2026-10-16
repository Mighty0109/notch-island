import XCTest
import SwiftUI
@testable import NotchIsland
import NotchIslandCore
import NotchIslandSensors

private final class FixedFooterSensors: PrivateSensorProvider {
    let reading: Reading<SensorValues>
    init(_ reading: Reading<SensorValues>) { self.reading = reading }
    func sample(now: Date) -> Reading<SensorValues> { reading }
}

/// 상태줄 센서 칸: 문구 · 숨김 · 폭(684pt) 계약.
@MainActor
final class SensorFooterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func ok(_ v: SensorValues) -> Reading<SensorValues> { .ok(v, unit: "°C", at: now, source: "SMC") }

    private func makeModel(_ reading: Reading<SensorValues>) async throws -> IslandModel {
        let suite = "com.mighty.notch-island.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.hoverExpand = false
        settings.localModelEnabled = false
        let model = IslandModel(settings: settings, sensors: FixedFooterSensors(reading))
        model.debugForceReduceMotion()
        model.start()
        model.click(.head)
        for _ in 0..<400 {
            if model.snapshot.sensors == reading { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        model.stop()
        XCTAssertEqual(model.snapshot.sensors, reading, "고정 Reading 이 수집기와 모델을 거쳐야 한다")
        return model
    }

    func testTextShowsMeanFanPercentWithoutTemperature() {
        XCTAssertEqual(IslandModel.sensorText(ok(SensorValues(cpuAverage: 80, fanRPMs: [2000, 6000], fanMaxRPMs: [4000, 8000]))), "fan 63%")
        XCTAssertEqual(IslandModel.sensorText(ok(SensorValues(fanRPMs: [995], fanMaxRPMs: [1000]))), "fan 100%")
        XCTAssertEqual(IslandModel.sensorText(ok(SensorValues(fanRPMs: [12000], fanMaxRPMs: [8000]))), "fan 100%")
        XCTAssertEqual(IslandModel.sensorText(ok(SensorValues(fanRPMs: [3000, 4000], fanMaxRPMs: [nil, 8000]))), "fan 50%")
    }

    func testStoppedFansAndFanlessMachines() {
        XCTAssertEqual(IslandModel.sensorText(ok(SensorValues(cpuAverage: 70, fanRPMs: [0, 0], fanMaxRPMs: [8000, 8000]))), "fan 정지")
        XCTAssertNil(IslandModel.sensorText(ok(SensorValues(cpuAverage: 38))), "팬 없는 기기")
        XCTAssertNil(IslandModel.sensorText(ok(SensorValues(fanRPMs: [4000]))), "최고 RPM 없음")
        XCTAssertNil(IslandModel.sensorText(ok(SensorValues(fanRPMs: [0, 0]))), "정지해도 최고 RPM 없으면 숨김")
        XCTAssertEqual(IslandModel.sensorText(ok(SensorValues(fanRPMs: [0, 4000], fanMaxRPMs: [8000, 8000]))), "fan 25%")
        XCTAssertEqual(IslandModel.sensorText(ok(SensorValues(fanRPMs: [1], fanMaxRPMs: [8000]))), "fan 0%", "반올림 0% 는 정지와 다름")
    }

    func testUnsupportedHidesCellAndCheckingFollowsExistingPattern() {
        XCTAssertNil(IslandModel.sensorText(.unsupported("x", unit: "°C", at: now, source: "SMC")), "미지원이면 칸 자체를 숨긴다")
        XCTAssertEqual(IslandModel.sensorText(.checking(unit: "°C", at: now, source: "SMC")), "fan 확인 중")
        XCTAssertEqual(IslandModel.sensorText(.failed("x", unit: "°C", at: now, source: "SMC")), "fan —")
        XCTAssertEqual(IslandModel.sensorText(Reading(value: nil, unit: "°C", timestamp: now, status: .ok, source: "SMC")), "fan 확인 중")
    }

    func testHelpListsAllAggregatesAndSource() {
        let h = IslandModel.sensorHelp(ok(SensorValues(cpuAverage: 70, cpuMax: 82, gpuAverage: 61, battery: 31, fanRPMs: [5012, 4990], fanMaxRPMs: [8000, 10000])))
        for needle in ["CPU 평균 70°C", "최대 82°C", "GPU 평균 61°C", "팬1 5012 rpm 63%", "팬2 4990 rpm 50%", "배터리 31°C", "SMC (비공개 · 키 의미 추정)"] {
            XCTAssertTrue(h.contains(needle), "\(needle) ⊄ \(h)")
        }
        let partial = IslandModel.sensorHelp(ok(SensorValues(fanRPMs: [3200, 12000], fanMaxRPMs: [nil, 8000])))
        XCTAssertTrue(partial.contains("팬1 3200 rpm · 팬2 12000 rpm 100%"))
    }

    func testUnreadableFirstFanKeepsActualNumbersThroughProviderAndModel() throws {
        for firstRPM in [nil, -1.0, 30001.0] as [Double?] {
            for secondRPM in [5300.0, 0] {
                let provider = SMCSensorProvider { FooterFanSMC(firstRPM: firstRPM, secondRPM: secondRPM) }
                let reading = provider.sample(now: now)
                XCTAssertEqual(reading.status, .ok)
                let v = try XCTUnwrap(reading.value)
                XCTAssertEqual(v.fanRPMs, [nil, secondRPM])
                let expectedText = secondRPM == 0 ? "fan 0%" : "fan 76%"
                XCTAssertEqual(IslandModel.sensorText(reading), expectedText)
                let help = IslandModel.sensorHelp(reading)
                let expectedFans = "팬1 — · 팬2 \(Int(secondRPM)) rpm \(secondRPM == 0 ? 0 : 76)%"
                XCTAssertTrue(help.contains(expectedFans), help)
                XCTAssertNotEqual(IslandModel.sensorText(reading), "fan 정지", "못 읽은 팬이 있으면 전부 정지로 단정하지 않는다")
                print("SMC fan F0Ac=\(String(describing: firstRPM)), F1Ac=\(Int(secondRPM)): \(expectedText), \(expectedFans)")
            }
        }
        let unreadable = ok(SensorValues(fanRPMs: [nil, nil], fanMaxRPMs: [8000, 7000]))
        XCTAssertNil(IslandModel.sensorText(unreadable))
        XCTAssertTrue(IslandModel.sensorHelp(unreadable).contains("팬1 — · 팬2 —"))
        XCTAssertNil(IslandModel.sensorText(ok(SensorValues(fanRPMs: [nil, 0], fanMaxRPMs: [8000, nil]))))
    }

    // MARK: 폭 — 684pt 고정 줄에서 가장 넓은 값끼리도 오른쪽 버튼과 겹치지 않는다

    private func naturalWidth(_ t: PowerlineTexts) -> CGFloat {
        let host = NSHostingView(rootView: PowerlineFooter.row(t, sensorHelp: "", e: .infinity))
        return host.fittingSize.width
    }

    private var widestSensor: String { IslandModel.sensorText(.checking(unit: "°C", at: now, source: "SMC"))! }

    private func texts(sensor: String?) -> PowerlineTexts {
        PowerlineTexts(clk: "23:59:59", mem: "mem 127.9/128G ◆", disk: "disk 1960G 남음", sensor: sensor)
    }

    func testWidestCellsFitIn684WithTheSensorCell() {
        let w = naturalWidth(texts(sensor: widestSensor))
        print("FOOTER natural width (widest, sensor on) = \(w)")
        XCTAssertLessThanOrEqual(w, 684, "가장 넓을 때 줄 자연 폭 \(w)pt 가 684pt 를 넘으면 버튼과 겹친다")
    }

    /// 기대 문구는 분기 표의 리터럴이다. 실제 row/seg/TypedLine 을 재사용하지 않는
    /// Text 견본이므로 fan 문구 누락·오표시·숨김 실패·버튼 문구 회귀도 검출한다.
    private func expectedRow(_ t: PowerlineTexts, sensor: String?) -> some View {
        func text(_ value: String, _ fg: Color, _ bg: Color) -> some View {
            Text(value).font(TermStyle.font(12)).foregroundColor(fg)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8).frame(height: 24).background(bg)
        }
        return HStack(spacing: 0) {
            text(t.clk, TermStyle.fg, TermStyle.segA)
            ChevronShape(pointsRight: true).fill(TermStyle.segA).frame(width: 8, height: 24).background(TermStyle.segB)
            text(t.mem, TermStyle.fg, TermStyle.segB)
            ChevronShape(pointsRight: true).fill(TermStyle.segB).frame(width: 8, height: 24).background(TermStyle.segC)
            text(t.disk, TermStyle.fg2, TermStyle.segC)
            if let sensor { text(sensor, TermStyle.fg2, TermStyle.segC) }
            Spacer(minLength: 0)
            ChevronShape(pointsRight: false).fill(TermStyle.segC).frame(width: 8, height: 24)
            Text("활성 상태 보기 열기").font(TermStyle.font(12, .semibold)).foregroundColor(TermStyle.fg)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12).frame(height: 24).background(TermStyle.segA)
        }
    }

    /// 자연 폭에서 그린 원본과 684pt 렌더의 좌/우 픽셀 열이 일치해야 한다.
    /// 달라도 되는 것은 Spacer의 투명한 폭뿐이다(글자 축소·잘림·버튼 겹침을 검출).
    private func assertUnchangedRendering(_ t: PowerlineTexts, expectedSensor: String?, naturalWidth: CGFloat,
                                          label: String, model: IslandModel? = nil) throws {
        func transparent(_ column: Data) -> Bool {
            stride(from: 3, to: column.count, by: 4).allSatisfy { column[$0] == 0 }
        }
        func columns<V: View>(_ content: V, width: CGFloat) throws -> [Data] {
            let renderer = ImageRenderer(content: content.frame(width: width, height: 24).padding(2))
            renderer.scale = 1
            let cg = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(cg.width, Int(width) + 4)
            XCTAssertEqual(cg.height, 28)
            var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            }
            var all: [Data] = []
            for x in 0..<cg.width {
                var column = Data()
                for y in 0..<cg.height {
                    let offset = (y * cg.width + x) * 4
                    column.append(contentsOf: bytes[offset..<(offset + 4)])
                }
                all.append(column)
            }
            for border in Array(all.prefix(2)) + Array(all.suffix(2)) {
                XCTAssertTrue(transparent(border), "\(label): 경계 밖으로 그림이 넘치면 안 된다")
            }
            return Array(all.dropFirst(2).dropLast(2))
        }
        let natural = try columns(PowerlineFooter.row(t, sensorHelp: "", e: .infinity), width: ceil(naturalWidth))
        let fixed: [Data]
        if let model {
            fixed = try columns(PowerlineFooter(model: model, e: .infinity), width: 684)
        } else {
            fixed = try columns(PowerlineFooter.row(t, sensorHelp: "", e: .infinity), width: 684)
        }
        let expected = try columns(expectedRow(t, sensor: expectedSensor), width: 684)
        // 색 공간 변환의 8비트 반올림 차이(1/255)만 허용하며 픽셀 위치는 바꾸지 않는다.
        func samePixels(_ lhs: Data, _ rhs: Data) -> Bool {
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
        }
        XCTAssertEqual(fixed.count, expected.count)
        let different = zip(fixed, expected).filter { !samePixels($0, $1) }.count
        XCTAssertEqual(different, 0, "\(label): 실제 footer 는 \(expectedSensor ?? "팬 칸 숨김") · 활성 상태 보기 열기 견본과 같아야 한다")
        let prefix = zip(natural, fixed).prefix { samePixels($0, $1) }.count
        let suffix = zip(natural.reversed(), fixed.reversed()).prefix { samePixels($0, $1) }.count
        if prefix + suffix < natural.count {
            let delta = zip(natural[prefix], fixed[prefix]).map { abs(Int($0) - Int($1)) }.max() ?? 0
            print("FOOTER render difference \(label): first differing column \(prefix), maximum channel delta \(delta)")
        }
        XCTAssertGreaterThanOrEqual(prefix + suffix, natural.count, "\(label): 684pt 렌더에서 글자·버튼 픽셀 손실/겹침 (좌 \(prefix), 우 \(suffix), 원본 \(natural.count))")
        if natural.count <= fixed.count, prefix + suffix >= natural.count {
            let gap = fixed[prefix..<(prefix + fixed.count - natural.count)]
            XCTAssertTrue(gap.allSatisfy(transparent), "\(label): 칸과 버튼 사이 추가 폭은 빈 Spacer여야 한다")
        }
    }

    func testEveryFormatterBranchFitsIn684WithWidestOtherCells() async throws {
        var cases: [(String, Reading<SensorValues>, String?)] = []
        for count in [1, 2] {
            for (rpm, expected) in [(0.0, "fan 정지"), (1, "fan 0%"), (100, "fan 1%"), (5000, "fan 50%"),
                                    (9950, "fan 100%"), (10000, "fan 100%"), (12000, "fan 100%")] {
                cases.append(("\(count)fan/\(rpm)rpm", ok(SensorValues(cpuAverage: 130,
                    fanRPMs: Array(repeating: rpm, count: count), fanMaxRPMs: Array(repeating: 10000, count: count))), expected))
            }
        }
        cases += [
            ("checking", .checking(unit: "°C", at: now, source: "SMC"), "fan 확인 중"),
            ("failed", .failed("x", unit: "°C", at: now, source: "SMC"), "fan —"),
            ("unsupported", .unsupported("x", unit: "°C", at: now, source: "SMC"), nil),
            ("fanless", ok(SensorValues(cpuAverage: 130, fanRPMs: [])), nil),
            ("nil value", Reading(value: nil, unit: "°C", timestamp: now, status: .ok, source: "SMC"), "fan 확인 중"),
            ("no maximum", ok(SensorValues(fanRPMs: [10000, 9000])), nil),
            ("stopped/no maximum", ok(SensorValues(fanRPMs: [0, 0])), nil),
            ("partial maximum", ok(SensorValues(fanRPMs: [5000, 4000], fanMaxRPMs: [nil, 8000])), "fan 50%"),
            ("mixed stopped", ok(SensorValues(fanRPMs: [0, 4000], fanMaxRPMs: [8000, 8000])), "fan 25%"),
            ("different maxima", ok(SensorValues(fanRPMs: [2000, 6000], fanMaxRPMs: [4000, 8000])), "fan 63%"),
            ("no CPU", ok(SensorValues(fanRPMs: [10000], fanMaxRPMs: [10000])), "fan 100%")
        ]
        var widest: (label: String, width: CGFloat) = ("", 0)
        var combinations = 0
        let memories = ["◇", "◈", "◆", "✓", "·"].map { "mem 127.9/128G \($0)" } + ["mem 확인 중"]
        for (label, reading, expectedSensor) in cases {
            let model = try await makeModel(reading)
            let fromModel = PowerlineTexts(model: model)
            XCTAssertEqual(fromModel.sensor, expectedSensor, "\(label): provider → 모델 → PowerlineTexts")
            try assertUnchangedRendering(fromModel, expectedSensor: expectedSensor, naturalWidth: naturalWidth(fromModel),
                                         label: "provider → PowerlineFooter/\(label)", model: model)
            for memory in memories {
                for disk in ["disk 1960G 남음", "disk 확인 중"] {
                    let branch = "\(label)/\(memory)/\(disk)"
                    // 센서 문구는 모델에서 온 그대로 두고, 기존 최대 길이의 다른 칸만 고정한다.
                    var t = fromModel
                    t.clk = "23:59:59"; t.mem = memory; t.disk = disk
                    let w = naturalWidth(t)
                    XCTAssertLessThanOrEqual(w, 684, "\(branch): 실제 footer 자연 폭 \(w)pt")
                    try assertUnchangedRendering(t, expectedSensor: expectedSensor, naturalWidth: w, label: branch)
                    if w > widest.width { widest = (branch, w) }
                    combinations += 1
                }
            }
            model.close()
            print("FOOTER provider → model → render: \(label) = \(expectedSensor ?? "hidden") (literal Text pixels)")
        }
        print("FOOTER matrix maximum = \(widest.width)pt (\(widest.label)), combinations = \(combinations)")
        print("FOOTER 684pt render comparisons = \(combinations) (natural pixels, channel tolerance 1/255, transparent spacer, outside bounds)")
    }

    func testFooterTextsContainNoBatteryOrNetworkCell() {
        let suite = "com.mighty.notch-island.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = IslandModel(settings: SettingsStore(defaults: defaults), sensors: nil)
        for t in [PowerlineTexts(model: model), texts(sensor: widestSensor)] {
            let strings = Mirror(reflecting: t).children.compactMap { $0.value as? String }
            XCTAssertFalse(strings.joined(separator: " | ").contains("bat"), "실제 모델/최대폭 상태줄에 bat 칸이 없어야 한다")
            XCTAssertFalse(Mirror(reflecting: t).children.contains { $0.label == "net" })
            XCTAssertFalse(strings.joined().contains("↓"))
            XCTAssertFalse(strings.joined().contains("↑"))
        }
    }

    func testTypicalCellsFitIn684WithTheSensorCell() {
        let t = PowerlineTexts(clk: "09:46:12", mem: "mem 101.0/128G ◇", disk: "disk 800G 남음", sensor: "fan 63%")
        let w = naturalWidth(t)
        print("FOOTER natural width (typical, sensor on) = \(w)")
        XCTAssertLessThanOrEqual(w, 684)
    }

    func testHiddenSensorCellRemovesItsWidth() {
        XCTAssertLessThan(naturalWidth(texts(sensor: nil)), naturalWidth(texts(sensor: widestSensor)))
    }
}

/// 실제 SMC 키에서 팬 번호와 읽기 실패가 모델의 호버까지 유지되는지 확인한다.
private final class FooterFanSMC: SMCSource {
    let firstRPM: Double?
    let secondRPM: Double
    init(firstRPM: Double?, secondRPM: Double) { self.firstRPM = firstRPM; self.secondRPM = secondRPM }
    func keyCount() -> Int? { 1 }
    func key(at index: Int) -> String? { index == 0 ? "FNum" : nil }
    func read(_ key: String) -> SMCValue? {
        if key == "FNum" { return SMCValue(type: "ui8", bytes: [2]) }
        let rpm: Double?
        switch key {
        case "F0Ac": rpm = firstRPM
        case "F1Ac": rpm = secondRPM
        case "F0Mx": rpm = 8000
        case "F1Mx": rpm = 7000
        default: rpm = nil
        }
        guard let rpm else { return nil }
        let bits = Float(rpm).bitPattern
        return SMCValue(type: "flt", bytes: (0..<4).map { UInt8((bits >> ($0 * 8)) & 0xff) })
    }
}
