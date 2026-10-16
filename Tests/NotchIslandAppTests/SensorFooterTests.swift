import XCTest
import SwiftUI
@testable import NotchIsland
import NotchIslandCore

/// 상태줄 센서 칸: 문구 · 숨김 · 폭(684pt) 계약.
@MainActor
final class SensorFooterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func ok(_ v: SensorValues) -> Reading<SensorValues> { .ok(v, unit: "°C", at: now, source: "SMC") }

    func testTextShowsCpuAverageAndFastestFan() {
        XCTAssertEqual(IslandModel.sensorText(ok(SensorValues(cpuAverage: 70.2, fanRPMs: [5000, 5312]))), "70° 5.3k rpm")
        XCTAssertEqual(IslandModel.sensorText(ok(SensorValues(cpuAverage: 99.4, fanRPMs: [7826]))), "99° 7.8k rpm")
        XCTAssertEqual(IslandModel.sensorText(ok(SensorValues(cpuAverage: 99.6, fanRPMs: [7826]))), "100° 7.8k rpm", "세 자리 온도에도 rpm 단위 유지")
        XCTAssertEqual(IslandModel.sensorText(ok(SensorValues(cpuAverage: 45, fanRPMs: [800]))), "45° 0.8k rpm")
    }

    func testStoppedFansAndFanlessMachines() {
        XCTAssertEqual(IslandModel.sensorText(ok(SensorValues(cpuAverage: 70, fanRPMs: [0, 0]))), "70° fan 정지")
        XCTAssertEqual(IslandModel.sensorText(ok(SensorValues(cpuAverage: 38, fanRPMs: []))), "38°", "팬 없는 기기")
        XCTAssertEqual(IslandModel.sensorText(ok(SensorValues(cpuAverage: 70, fanRPMs: [0, 4000]))), "70° 4.0k rpm", "한 대라도 돌면 가장 빠른 팬")
    }

    func testUnsupportedHidesCellAndCheckingFollowsExistingPattern() {
        XCTAssertNil(IslandModel.sensorText(.unsupported("x", unit: "°C", at: now, source: "SMC")), "미지원이면 칸 자체를 숨긴다")
        XCTAssertEqual(IslandModel.sensorText(.checking(unit: "°C", at: now, source: "SMC")), "temp 확인 중")
        XCTAssertEqual(IslandModel.sensorText(.failed("x", unit: "°C", at: now, source: "SMC")), "temp 확인 중")
        XCTAssertEqual(IslandModel.sensorText(ok(SensorValues(cpuAverage: nil, fanRPMs: [5000]))), "—° 5.0k rpm")
    }

    func testHelpListsAllAggregatesAndSource() {
        let h = IslandModel.sensorHelp(ok(SensorValues(cpuAverage: 70, cpuMax: 82, gpuAverage: 61, battery: 31, fanRPMs: [5012, 4990])))
        for needle in ["CPU 평균 70°C", "최대 82°C", "GPU 평균 61°C", "팬1 5012 rpm", "팬2 4990 rpm", "배터리 31°C", "SMC (비공개 · 키 의미 추정)"] {
            XCTAssertTrue(h.contains(needle), "\(needle) ⊄ \(h)")
        }
    }

    // MARK: 폭 — 684pt 고정 줄에서 가장 넓은 값끼리도 오른쪽 버튼과 겹치지 않는다

    private func naturalWidth(_ t: PowerlineTexts) -> CGFloat {
        let host = NSHostingView(rootView: PowerlineFooter.row(t, sensorHelp: "", e: .infinity))
        return host.fittingSize.width
    }

    private var widestSensor: String { IslandModel.sensorText(ok(SensorValues(cpuAverage: 130, fanRPMs: [10000])))! }

    private func texts(sensor: String?) -> PowerlineTexts {
        PowerlineTexts(clk: "23:59:59", mem: "mem 127.9/128G ◆", disk: "disk 1960G 남음", net: "↓999K ↑999K", sensor: sensor)
    }

    func testWidestCellsFitIn684WithTheSensorCell() {
        let w = naturalWidth(texts(sensor: widestSensor))
        print("FOOTER natural width (widest, sensor on) = \(w)")
        XCTAssertLessThanOrEqual(w, 684, "가장 넓을 때 줄 자연 폭 \(w)pt 가 684pt 를 넘으면 버튼과 겹친다")
    }

    /// 자연 폭에서 그린 원본과 684pt 렌더의 좌/우 픽셀 열이 일치해야 한다.
    /// 달라도 되는 것은 Spacer의 투명한 폭뿐이다(글자 축소·잘림·버튼 겹침을 검출).
    private func assertUnchangedRendering(_ t: PowerlineTexts, naturalWidth: CGFloat, label: String) throws {
        func transparent(_ column: Data) -> Bool {
            stride(from: 3, to: column.count, by: 4).allSatisfy { column[$0] == 0 }
        }
        func columns(width: CGFloat) throws -> [Data] {
            let renderer = ImageRenderer(content: PowerlineFooter.row(t, sensorHelp: "", e: .infinity)
                .frame(width: width, height: 24).padding(2))
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
        let natural = try columns(width: ceil(naturalWidth))
        let fixed = try columns(width: 684)
        // 색 공간 변환의 8비트 반올림 차이(1/255)만 허용하며 픽셀 위치는 바꾸지 않는다.
        func samePixels(_ lhs: Data, _ rhs: Data) -> Bool {
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
        }
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

    func testEveryFormatterBranchFitsIn684WithWidestOtherCells() throws {
        var cases: [(String, Reading<SensorValues>)] = []
        for temp in [70.0, 99.4, 99.6, 100, 130] {
            for rpm in [0.0, 7826, 10000] {
                cases.append(("\(temp)C/\(rpm)rpm", ok(SensorValues(cpuAverage: temp, fanRPMs: [rpm]))))
            }
        }
        cases += [
            ("checking", .checking(unit: "°C", at: now, source: "SMC")),
            ("failed", .failed("x", unit: "°C", at: now, source: "SMC")),
            ("unsupported", .unsupported("x", unit: "°C", at: now, source: "SMC")),
            ("fanless", ok(SensorValues(cpuAverage: 130, fanRPMs: []))),
            ("no CPU", ok(SensorValues(cpuAverage: nil, fanRPMs: [10000])))
        ]
        var widest: (label: String, width: CGFloat) = ("", 0)
        for (label, reading) in cases {
            let sensor = IslandModel.sensorText(reading)
            let t = texts(sensor: sensor)
            let w = naturalWidth(t)
            print("FOOTER case \(label) [\(sensor ?? "hidden")] natural width = \(w)")
            XCTAssertLessThanOrEqual(w, 684, "\(label): 실제 footer 자연 폭 \(w)pt")
            try assertUnchangedRendering(t, naturalWidth: w, label: label)
            if w > widest.width { widest = (label, w) }
        }
        print("FOOTER matrix maximum = \(widest.width)pt (\(widest.label)), combinations = \(cases.count)")
        print("FOOTER 684pt render comparisons = \(cases.count) (natural pixels, channel tolerance 1/255, transparent spacer, outside bounds)")
    }

    func testFooterTextsContainNoBatCell() {
        let suite = "com.mighty.notch-island.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = IslandModel(settings: SettingsStore(defaults: defaults), sensors: nil)
        for t in [PowerlineTexts(model: model), texts(sensor: widestSensor)] {
            let strings = Mirror(reflecting: t).children.compactMap { $0.value as? String }
            XCTAssertFalse(strings.joined(separator: " | ").contains("bat"), "실제 모델/최대폭 상태줄에 bat 칸이 없어야 한다")
        }
    }

    func testTypicalCellsFitIn684WithTheSensorCell() {
        let t = PowerlineTexts(clk: "09:46:12", mem: "mem 101.0/128G ◇", disk: "disk 800G 남음", net: "↓1.2M ↑0.4K", sensor: "70° 5.3k rpm")
        let w = naturalWidth(t)
        print("FOOTER natural width (typical, sensor on) = \(w)")
        XCTAssertLessThanOrEqual(w, 684)
    }

    func testHiddenSensorCellRemovesItsWidth() {
        XCTAssertLessThan(naturalWidth(texts(sensor: nil)), naturalWidth(texts(sensor: widestSensor)))
    }
}
