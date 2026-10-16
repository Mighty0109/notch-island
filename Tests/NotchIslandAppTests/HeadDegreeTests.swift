import XCTest
import SwiftUI
import AppKit
@testable import NotchIsland
import NotchIslandCore

private final class FixedHeadSensors: PrivateSensorProvider {
    let reading: Reading<SensorValues>
    init(_ reading: Reading<SensorValues>) { self.reading = reading }
    func sample(now: Date) -> Reading<SensorValues> { reading }
}

private struct FixedHeadThermal: ThermalSource {
    let state: ProcessInfo.ThermalState
    func currentState() -> ProcessInfo.ThermalState { state }
}

@MainActor
final class HeadDegreeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private func ok(_ average: Double?) -> Reading<SensorValues> {
        .ok(SensorValues(cpuAverage: average), unit: "°C", at: now, source: "fixed test provider")
    }

    private var thermalCases: [(state: ProcessInfo.ThermalState, word: String, glyph: String, color: Color)] {
        [(.nominal, "보통", "◇", ThemeStyle.matrix.ok), (.fair, "주의", "◈", ThemeStyle.matrix.warn),
         (.serious, "높음", "◆", ThemeStyle.matrix.high), (.critical, "매우 높음", "◉", ThemeStyle.matrix.high)]
    }

    private func makeModel(_ reading: Reading<SensorValues>, job: Bool,
                           thermal: ProcessInfo.ThermalState = .serious) async throws -> IslandModel {
        let suite = "com.mighty.notch-island.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.hoverExpand = false
        settings.localModelEnabled = false
        let model = IslandModel(settings: settings, thermal: ThermalProvider(source: FixedHeadThermal(state: thermal)),
                                sensors: FixedHeadSensors(reading))
        model.debugForceReduceMotion()
        // 첫 스냅샷 전부터 공개 단계·작업을 고정한다(배치 히스테리시스에도 실기 이력이 섞이지 않게).
        if job { model.debugToggleCharging() } else { model.debugSuppressJob() }
        model.debugTrigger(.memory)
        model.start()
        model.click(.head)
        for _ in 0..<400 {
            if model.snapshot.sensors.timestamp == reading.timestamp,
               model.snapshot.sensors.source == reading.source { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        model.stop()
        // NaN 은 자신과도 같지 않으므로 도착 여부는 고정 시각·출처·상태로 확인한다.
        XCTAssertEqual(model.snapshot.sensors.timestamp, reading.timestamp, "가짜 센서값이 수집 경로를 통해 도착해야 한다")
        XCTAssertEqual(model.snapshot.sensors.source, reading.source)
        XCTAssertEqual(model.snapshot.sensors.status, reading.status)
        XCTAssertEqual(model.snapshot.thermal.value, ThermalProvider.level(from: thermal))
        return model
    }

    func testThermalWordUsesRoundedCpuAverageAndKeepsFallbackForEveryLevel() {
        let fallbacks: [Reading<SensorValues>] = [
            .checking(unit: "°C", at: now, source: "fixed"),
            .failed("x", unit: "°C", at: now, source: "fixed"),
            .unsupported("x", unit: "°C", at: now, source: "fixed"),
            Reading(value: nil, unit: "°C", timestamp: now, status: .ok, source: "fixed"),
            ok(nil), ok(0), ok(-1), ok(131), ok(.nan), ok(.infinity)
        ]
        for level in ThermalLevel.allCases {
            for reading in fallbacks { XCTAssertEqual(IslandModel.thermalWord(level, sensors: reading), level.label) }
            for (input, expected) in [(9.0, "9°"), (80.0, "80°"), (99.5, "100°"), (100.0, "100°"), (130.0, "130°")] {
                XCTAssertEqual(IslandModel.thermalWord(level, sensors: ok(input)), expected)
            }
        }
    }

    /// 실제 HeadStrip 을 카드가 받치는 폭과 내용에 꼭 맞춘 날개 폭 양쪽으로 렌더한다.
    /// 바깥 여백·내용 안쪽 끝·카메라 픽셀까지 검사해 좁은 날개에서의 침범을 검출한다.
    private func assertRenderedInsideWings(_ model: IslandModel, expectedWord: String, tight: Bool,
                                          expectedGlyph: String = "◆", expectedColor: Color = ThemeStyle.matrix.high) async throws {
        let layout = model.layout
        let open = model.phase.isOpen
        let ends = IslandGeometry.ends(layout.shape, progress: open ? 1 : 0)
        let wings = open ? layout.wingsOpen : layout.wingsCollapsed
        let left = tight ? wings.left : CGFloat(ends.left) - layout.notchWidth / 2
        let right = tight ? wings.right : CGFloat(ends.right) - layout.notchWidth / 2
        let width = left + layout.notchWidth + right
        var edges = HeadEdges()
        let root = HeadStrip(model: model, wingLeft: left, wingRight: right, notchWidth: layout.notchWidth)
            .frame(width: width, height: layout.notchHeight, alignment: .topLeading)
            .onPreferenceChange(HeadEdgesKey.self) { edges = $0 }
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: layout.notchHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 60_000_000)
        host.layoutSubtreeIfNeeded()
        let pad = HeadSpacing.at(open: open).wingPad
        XCTAssertEqual(try XCTUnwrap(edges.leftMinX), pad, accuracy: 1)
        XCTAssertEqual(width - (try XCTUnwrap(edges.rightMaxX)), pad, accuracy: 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(edges.leftMaxX), left - pad + 1, "왼쪽 내용이 카메라 쪽 여백을 침범하면 안 된다")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(edges.rightMinX), left + layout.notchWidth + pad - 1, "오른쪽 내용이 카메라 쪽 여백을 침범하면 안 된다")
        if tight {
            XCTAssertEqual(try XCTUnwrap(edges.leftMaxX), left - pad, accuracy: 1, "계산한 왼쪽 날개 폭과 실제 내용 폭 일치")
            XCTAssertEqual(try XCTUnwrap(edges.rightMinX), left + layout.notchWidth + pad, accuracy: 1, "자릿수와 무관하게 예약한 온도 폭을 실제 렌더에도 반영")
        }

        let renderer = ImageRenderer(content: root.padding(2))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 }, "빈 이미지가 아닌 실제 머리줄 렌더여야 한다")
        let camera = Int(ceil(left)) + 2..<Int(floor(left + layout.notchWidth)) + 2
        XCTAssertTrue((0..<image.height).allSatisfy { y in
            camera.allSatisfy { x in pixels[(y * image.width + x) * 4 + 3] == 0 }
        }, "카메라 영역은 투명해야 한다")
        XCTAssertTrue((0..<image.height).allSatisfy { y in
            [0, 1, image.width - 2, image.width - 1].allSatisfy { x in pixels[(y * image.width + x) * 4 + 3] == 0 }
        }, "섬 바깥 잘림/넘침 없음")
        try assertThermalPixels(image, model: model, expectedWord: expectedWord,
                                expectedGlyph: expectedGlyph, expectedColor: expectedColor,
                                rightEdge: XCTUnwrap(edges.rightMaxX), width: width)
        print("HEAD degree=\(model.display(.thermal).value) open=\(open) tight=\(tight) wings=\(left)/\(right) camera pixels clear")
    }

    /// 실제 머리줄의 열 칸을 독립적인 Text 견본과 비교한다. 모델의 display/thermalWord 와
    /// WordSlot/SlotView 를 견본에 쓰지 않아 문구 누락·오표시·접힘의 °C 잔상을 검출한다.
    private func assertThermalPixels(_ actual: CGImage, model: IslandModel, expectedWord: String,
                                     expectedGlyph: String, expectedColor: Color,
                                     rightEdge: CGFloat, width: CGFloat) throws {
        let open = model.phase.isOpen
        let sp = HeadSpacing.at(open: open)
        let st = ThemeStyle.matrix
        let wordWidth = model.measureWord(expectedWord.hasSuffix("°") ? "100°" : expectedWord)
        let thermalWidth = HeadMetrics.thermIcon + sp.iconValue + HeadMetrics.glyph
            + (open ? sp.iconValue + model.measureWord("temp") + sp.glyphWord + wordWidth : 0)
        let jobWidth = model.job.map {
            sp.ringGap + HeadMetrics.ring + (open ? sp.glyphWord + model.measureWord(model.jobLabelText($0)) : 0)
        } ?? 0
        let end = rightEdge - jobWidth
        let start = end - thermalWidth
        let expected = HStack(spacing: 0) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: HeadMetrics.icon, weight: .semibold)).foregroundColor(st.on2)
                .frame(width: HeadMetrics.thermIcon)
            if open {
                Text("temp").font(st.font(HeadMetrics.word, .semibold)).foregroundColor(st.on3)
                    .fixedSize().frame(width: model.measureWord("temp"), alignment: .leading)
                    .padding(.leading, sp.iconValue)
            }
            Text(expectedGlyph).font(st.font(HeadMetrics.text, .bold)).foregroundColor(expectedColor)
                .frame(width: HeadMetrics.glyph).padding(.leading, sp.iconValue)
            if open {
                Text(expectedWord).font(st.font(HeadMetrics.word, .semibold)).foregroundColor(st.on2)
                    .fixedSize().padding(.leading, sp.glyphWord)
                    .frame(width: wordWidth + sp.glyphWord, alignment: .leading)
            }
        }
        .offset(x: start)
        .frame(width: width, height: model.layout.notchHeight, alignment: .topLeading).padding(2)
        let renderer = ImageRenderer(content: expected)
        renderer.scale = 1
        let reference = try XCTUnwrap(renderer.cgImage)
        func inkRows(_ image: CGImage, xs: Range<Int>) throws -> [[UInt8]] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            var rows = (0..<image.height).map { y in Array(bytes[(y * image.width + xs.lowerBound) * 4..<(y * image.width + xs.upperBound) * 4]) }
            func clear(_ row: [UInt8]) -> Bool { stride(from: 3, to: row.count, by: 4).allSatisfy { row[$0] == 0 } }
            // 각 Text/SF Symbol 의 수직 반올림은 부모 HStack 의 높이에 따라 1px 달라질 수 있다.
            while let row = rows.first, clear(row) { rows.removeFirst() }
            while let row = rows.last, clear(row) { rows.removeLast() }
            return rows
        }
        var x = start
        let parts = [("icon", HeadMetrics.thermIcon, CGFloat(0)), ("temp", open ? sp.iconValue + model.measureWord("temp") : 0, sp.iconValue),
                     (expectedGlyph, sp.iconValue + HeadMetrics.glyph, sp.iconValue), (expectedWord, open ? sp.glyphWord + wordWidth : 0, sp.glyphWord)]
        for (part, partWidth, leading) in parts where partWidth > 0 {
            // 앞 여백에는 SF Symbol 의 프레임 밖 잉크가 걸칠 수 있으므로 글자 자리만 비교한다.
            let xs = Int(floor(x + leading)) + 2..<Int(ceil(x + partWidth)) + 2
            let actualRows = try inkRows(actual, xs: xs), expectedRows = try inkRows(reference, xs: xs)
            XCTAssertFalse(expectedRows.isEmpty, "\(part): 문자 견본이 비어 있으면 안 된다")
            XCTAssertEqual(actualRows.count, expectedRows.count, "\(part), open=\(open): 열 칸 글자 높이")
            let same = actualRows.count == expectedRows.count && zip(actualRows, expectedRows).allSatisfy { a, b in
                a.count == b.count && zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
            }
            XCTAssertTrue(same, "실제 HeadStrip 의 \(part), open=\(open) 는 독립 Text 견본 픽셀과 같아야 한다")
            x += partWidth
        }
    }

    func testOneTwoAndThreeDigitDegreesHaveStableWingsAndNoClipping() async throws {
        for job in [false, true] {
            var referenceOpen: IslandLayout.Wings?
            var referenceCollapsed: IslandLayout.Wings?
            for degree in [9.0, 80, 100, 130] {
                let model = try await makeModel(ok(degree), job: job)
                XCTAssertEqual(model.display(.thermal).value, "\(Int(degree))°")
                XCTAssertEqual(model.display(.thermal).glyph, "◆", "공개 열 단계 기호 유지")
                XCTAssertEqual(model.display(.thermal).spoken, "열 상태 높음")
                XCTAssertEqual(model.thermalWordWidth, model.measureWord("100°"))
                XCTAssertGreaterThanOrEqual(model.thermalWordWidth, model.measureWord(model.display(.thermal).value))
                if let referenceOpen { XCTAssertEqual(model.wings.open, referenceOpen) }
                if let referenceCollapsed { XCTAssertEqual(model.wings.collapsed, referenceCollapsed) }
                referenceOpen = model.wings.open; referenceCollapsed = model.wings.collapsed
                try await assertRenderedInsideWings(model, expectedWord: "\(Int(degree))°", tight: false)
                try await assertRenderedInsideWings(model, expectedWord: "\(Int(degree))°", tight: true)
                model.close()
                try await assertRenderedInsideWings(model, expectedWord: "\(Int(degree))°", tight: true)
                XCTAssertEqual(model.wings.collapsed, referenceCollapsed)
            }
        }
    }

    func testFallbackBranchesRenderInsideWingsAndKeepCollapsedSize() async throws {
        let readings: [Reading<SensorValues>] = [
            ok(nil),
            .checking(unit: "°C", at: now, source: "fixed"),
            .failed("x", unit: "°C", at: now, source: "fixed"),
            .unsupported("x", unit: "°C", at: now, source: "fixed"),
            Reading(value: nil, unit: "°C", timestamp: now, status: .ok, source: "fixed"),
            ok(0), ok(-1), ok(131), ok(.nan), ok(.infinity)
        ]
        for thermal in thermalCases {
            for job in [false, true] {
                let degreeModel = try await makeModel(ok(80), job: job, thermal: thermal.state)
                let collapsed = degreeModel.wings.collapsed
                for reading in readings {
                    let model = try await makeModel(reading, job: job, thermal: thermal.state)
                    XCTAssertEqual(model.display(.thermal).value, thermal.word)
                    XCTAssertEqual(model.display(.thermal).glyph, thermal.glyph)
                    XCTAssertEqual(model.wings.collapsed, collapsed, "SMC 값 유무는 접힘 폭에 영향을 주지 않는다")
                    try await assertRenderedInsideWings(model, expectedWord: thermal.word, tight: true,
                                                        expectedGlyph: thermal.glyph, expectedColor: thermal.color)
                    model.close()
                    try await assertRenderedInsideWings(model, expectedWord: thermal.word, tight: true,
                                                        expectedGlyph: thermal.glyph, expectedColor: thermal.color)
                }
            }
        }
    }

    func testCpuDegreesKeepEveryPublicThermalGlyphInTheRenderedHead() async throws {
        for thermal in thermalCases {
            for job in [false, true] {
                let model = try await makeModel(ok(80), job: job, thermal: thermal.state)
                XCTAssertEqual(model.display(.thermal).value, "80°")
                XCTAssertEqual(model.display(.thermal).glyph, thermal.glyph)
                XCTAssertEqual(model.display(.thermal).spoken, "열 상태 " + thermal.word)
                try await assertRenderedInsideWings(model, expectedWord: "80°", tight: true,
                                                    expectedGlyph: thermal.glyph, expectedColor: thermal.color)
                model.close()
                try await assertRenderedInsideWings(model, expectedWord: "80°", tight: true,
                                                    expectedGlyph: thermal.glyph, expectedColor: thermal.color)
            }
        }
    }

    func testRoundedHalfDegreeIsActuallyRenderedAs100Degrees() async throws {
        let model = try await makeModel(ok(99.5), job: false)
        try await assertRenderedInsideWings(model, expectedWord: "100°", tight: true)
        model.close()
        try await assertRenderedInsideWings(model, expectedWord: "100°", tight: true)
    }
}
