import XCTest
import SwiftUI
import Combine
@testable import NotchIsland
import NotchIslandCore

/// 앱 쪽(IslandModel · 코드 비 그리기) 성능 회귀 테스트. 프로파일(2026-10-03)에서 확인된 비용을 되돌리는 변경을 막는다.
@MainActor
final class PerformanceRegressionTests: XCTestCase {
    private func makeModel(hover: Bool = false) -> (IslandModel, SettingsStore) {
        let suite = "com.mighty.notch-island.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        addTeardownBlock { d.removePersistentDomain(forName: suite) }       // 남은 빈 plist 는 scripts/test.sh 가 지운다
        let settings = SettingsStore(defaults: d)
        settings.hoverExpand = hover
        return (IslandModel(settings: settings), settings)
    }

    /// 같은 구역 이벤트가 반복돼도 모델이 SwiftUI 에 알리는(publish) 일이 0회여야 한다 — 알리면 마우스 이벤트마다 뷰가 다시 그려진다.
    func testRepeatedSameZonePointerEventsPublishNothing() {
        let (model, _) = makeModel(hover: false)
        var publishes = 0
        let sub = model.objectWillChange.sink { _ in publishes += 1 }
        defer { sub.cancel() }
        for _ in 0..<1000 { model.pointerMoved(.head) }
        for _ in 0..<1000 { model.pointerMoved(.none) }
        for _ in 0..<1000 { model.pointerMoved(.head); model.pointerMoved(.card) }
        XCTAssertEqual(publishes, 0, "구역이 같아도(호버 꺼짐) 포인터 이벤트 4000번에 publish 0회")
    }

    /// 마우스 이벤트 경로가 읽는 `layout` 은 캐시다 — 읽어도 새로 만들지 않고(같은 값), 입력이 바뀌면 즉시 따라간다.
    func testLayoutCacheMatchesInputsAndTracksPhase() {
        let (model, _) = makeModel()
        func expected() -> IslandLayout {
            let g = model.geometry
            return IslandLayout(phase: model.phase, notchWidth: ceil((g?.notchWidth ?? 200) / 2) * 2, notchHeight: g?.notchHeight ?? 38,
                                wingsCollapsed: model.wings.collapsed, wingsOpen: model.wings.open,
                                cardHeight: model.cardHeight, pillWidth: model.pillWidth)
        }
        XCTAssertEqual(model.layout, expected())
        XCTAssertEqual(model.layout.phase, .collapsed)
        let collapsedHeight = model.layout.island.height

        model.click(.head)                                   // 고정으로 펼침
        XCTAssertEqual(model.phase, .pinned)
        XCTAssertEqual(model.layout, expected(), "단계가 바뀌면 캐시도 같은 값으로 갱신")
        XCTAssertEqual(model.layout.phase, .pinned)
        XCTAssertGreaterThan(model.layout.island.height, collapsedHeight)

        model.updateCardHeight(300)
        XCTAssertEqual(model.cardHeight, 300)
        XCTAssertEqual(model.layout, expected(), "카드 높이가 바뀌면 캐시도 따라간다")
        XCTAssertEqual(model.layout.cardHeight, 300)

        model.close()
        XCTAssertEqual(model.layout, expected())
        XCTAssertEqual(model.layout.phase, .collapsed)
    }

    /// 로그가 꺼져 있으면(기본) 로그 문자열은 만들지도 않는다(예전엔 마우스 이벤트마다 enum 을 문자열로 바꿨다).
    func testTraceMessageIsNotBuiltWhenTraceOff() throws {
        try XCTSkipIf(IslandModel.traceOn, "NOTCH_ISLAND_TRACE 가 켜진 환경에서는 건너뜀")
        let (model, _) = makeModel()
        var built = 0
        model.trace({ built += 1; return "x" }())
        XCTAssertEqual(built, 0)
    }

    /// 코드 비: 지속 시간 안에는 그려지고, 끝나면 아무것도 안 그린다. (그리기 방식 최적화가 모양을 지웠는지 보는 최소 확인 —
    /// 예전 방식과의 픽셀 동일성은 decisions D15 에 하네스 결과로 기록)
    func testCodeRainPaintsDuringRunAndNothingAfter() {
        func litPixels(t: Double) -> Int {
            let view = Canvas { ctx, size in CodeRainPainter.draw(&ctx, size: size, t: t, color: .green) }
                .frame(width: 240, height: 300).background(Color.black)
            let r = ImageRenderer(content: view); r.scale = 1
            guard let cg = r.cgImage else { return -1 }
            var buf = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let c = CGContext(data: &buf, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            var n = 0
            var i = 1
            while i < buf.count { if buf[i] > 40 { n += 1 }; i += 4 }       // 초록 채널이 켜진 픽셀
            return n
        }
        XCTAssertGreaterThan(litPixels(t: 0.3), 200, "비가 내리는 중엔 글자가 그려진다")
        XCTAssertEqual(litPixels(t: CodeRainPainter.duration + 0.01), 0, "끝난 뒤엔 아무것도 안 그린다")
        XCTAssertEqual(litPixels(t: -0.1), 0, "시작 전엔 아무것도 안 그린다")
    }
}
