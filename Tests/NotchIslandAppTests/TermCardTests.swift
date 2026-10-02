import XCTest
import SwiftUI
@testable import NotchIsland
import NotchIslandCore

/// 안 4 카드(터미널 IDE + 매트릭스)의 뷰 쪽 계약: 줄 글자 계산·카드 높이 고정·점선 링.
@MainActor
final class TermCardTests: XCTestCase {
    private func makeModel() -> IslandModel {
        let suite = "com.mighty.notch-island.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        let s = SettingsStore(defaults: d)
        s.hoverExpand = false
        return IslandModel(settings: s)
    }

    private func text(_ a: AttributedString) -> String { String(a.characters) }

    private let segs = [TermSeg("❯", .green, .heavy), TermSeg(" ◇ ", .green, .bold), TermSeg("메모리 압박 주의 · ComfyUI 38.2GB", .white, .semibold)]
    private var real: String { segs.map(\.text).joined() }

    /// 연출이 끝나면(무한대 · 충분히 지난 시간) 화면 글자는 실제 글자와 정확히 같다 — 가타카나가 남지 않는다
    func testSettledLineIsExactlyTheRealText() {
        XCTAssertEqual(text(TypedLine.attributed(segs: segs, size: 12, elapsed: .infinity, cps: RevealTiming.cardCharsPerSecond, caret: nil)), real)
        let late = RevealTiming.settleDuration(chars: real.count) + 0.05
        XCTAssertEqual(text(TypedLine.attributed(segs: segs, size: 12, elapsed: late, cps: RevealTiming.cardCharsPerSecond, caret: nil)), real)
    }

    /// 타이핑 중: 줄 길이 불변(안 드러난 글자도 투명으로 자리를 잡는다), 굳은 앞부분은 진짜 글자, 섞인 글자는 가타카나(영숫자·한글 자리만)
    func testMidTypingKeepsLengthSettledPrefixAndKanaOnlyInScrambledSlots() {
        let chars = Array(real)
        for ms in stride(from: 0, through: 400, by: 10) {
            let e = Double(ms) / 1000
            let out = Array(text(TypedLine.attributed(segs: segs, size: 12, elapsed: e, cps: RevealTiming.cardCharsPerSecond, caret: nil)))
            XCTAssertEqual(out.count, chars.count, "\(ms)ms: 줄 글자 수 유지(글자가 밀리지 않음)")
            let settled = RevealTiming.settledCount(chars: chars.count, elapsed: e), revealed = RevealTiming.revealedCount(chars: chars.count, elapsed: e)
            XCTAssertEqual(Array(out[0..<settled]), Array(chars[0..<settled]), "\(ms)ms: 굳은 글자는 진짜 글자")
            for i in settled..<revealed where GlyphScramble.isScrambled(chars[i]) { XCTAssertFalse(out[i].isASCII, "\(ms)ms [\(i)]: 섞이는 중엔 가타카나") }
            for i in settled..<revealed where !GlyphScramble.isScrambled(chars[i]) { XCTAssertEqual(out[i], chars[i], "기호·공백은 해독 중에도 그대로") }
            for i in revealed..<chars.count { XCTAssertEqual(out[i], chars[i], "안 드러난 글자도 레이아웃 자리는 진짜 글자(투명)") }
        }
    }

    /// 알림 문구 커서: 타이핑 앞쪽에 붙고(글자 1개 추가), 끝나고 1.1초 뒤엔 사라진다
    func testCaretOnlyWhileTypingOrLingering() {
        let cps = RevealTiming.pillCharsPerSecond
        let during = text(TypedLine.attributed(segs: segs, size: 13, elapsed: 0.05, cps: cps, caret: .green))
        XCTAssertEqual(during.count, real.count + 1); XCTAssertTrue(during.contains("█"))
        let gone = RevealTiming.settleDuration(chars: real.count, charsPerSecond: cps) + RevealTiming.pillCaretLinger + 0.1
        let after = text(TypedLine.attributed(segs: segs, size: 13, elapsed: gone, cps: cps, caret: .green))
        XCTAssertEqual(after, real); XCTAssertFalse(after.contains("█"))
        XCTAssertEqual(text(TypedLine.attributed(segs: segs, size: 13, elapsed: .infinity, cps: cps, caret: .green)), real, "움직임 줄이기(무한대)엔 커서도 없다")
    }

    func testDashRingLitCount() {
        XCTAssertEqual(DashRing.litCount(percent: 0), 0)
        XCTAssertEqual(DashRing.litCount(percent: 62), 6)
        XCTAssertEqual(DashRing.litCount(percent: 65), 7)
        XCTAssertEqual(DashRing.litCount(percent: 100), 10)
        XCTAssertEqual(DashRing.litCount(percent: 140), 10); XCTAssertEqual(DashRing.litCount(percent: -3), 0)
    }

    private func renderedHeight(_ model: IslandModel, t: Double) -> CGFloat {
        let r = ImageRenderer(content: CardBody(model: model, t: t).background(Color.black)); r.scale = 1
        return CGFloat(r.cgImage?.height ?? -1)
    }

    /// 섹션 자리 예약: 데이터가 없을 때·있을 때·연출 중·연출 끝 모두 같은 높이 → 값이 도착해도 섬 높이가 안 튄다. 모델 초기값과도 같다.
    func testCardHeightIsFixedRegardlessOfDataAndReveal() {
        let model = makeModel()
        let empty = renderedHeight(model, t: .infinity)
        XCTAssertEqual(empty, 426, accuracy: 1)
        XCTAssertEqual(CGFloat(model.cardHeight), empty, accuracy: 1, "첫 펼침에서 높이가 안 튀게 모델 초기값 = 실제 높이")
        for t in [0.0, 0.1, 0.3, 0.6] { XCTAssertEqual(renderedHeight(model, t: t), empty, accuracy: 1, "연출 \(t)초에도 같은 높이") }

        model.start()
        let exp = expectation(description: "수집")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { exp.fulfill() }
        wait(for: [exp], timeout: 6)
        model.stop()
        XCTAssertNotNil(model.snapshot.cpu.value, "데이터가 실제로 들어옴")
        XCTAssertEqual(renderedHeight(model, t: .infinity), empty, accuracy: 1, "데이터가 와도 높이 불변")
        XCTAssertEqual(renderedHeight(model, t: 0.3), empty, accuracy: 1)
    }

    /// 펼치면 로그가 3줄로 채워진다(빈 자리 없음)
    func testOpeningSeedsThreeLogLines() {
        let model = makeModel()
        XCTAssertTrue(model.statusLog.lines.isEmpty)
        model.click(.head)
        XCTAssertEqual(model.phase, .pinned)
        XCTAssertEqual(model.statusLog.lines.count, StatusLog.capacity)
    }
}

/// 캡처 하네스(평소엔 건너뜀): `NOTCH_ISLAND_CAPTURE_DIR=<폴더>` 를 주면 창·입력 없이 카드를 ImageRenderer 로 시각별로 그려 PNG 로 남긴다.
/// 데이터는 실제 수집값(3초 수집 뒤). 펼침 프레임 시퀀스(0~1초)·펼침 정지·알림 문구 프레임용.
@MainActor
final class CardCaptureHarness: XCTestCase {
    func testCaptureCardFrames() throws {
        guard let dir = ProcessInfo.processInfo.environment["NOTCH_ISLAND_CAPTURE_DIR"] else { throw XCTSkip("NOTCH_ISLAND_CAPTURE_DIR 없음") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let suite = "com.mighty.notch-island.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        let model = IslandModel(settings: SettingsStore(defaults: d))
        model.click(.head)
        model.start()
        let exp = expectation(description: "수집"); DispatchQueue.main.asyncAfter(deadline: .now() + 3.3) { exp.fulfill() }
        wait(for: [exp], timeout: 8)
        model.stop()
        func save(_ name: String, t: Double) {
            let view = CardFrame(model: model, t: t).background(Color.black)
            let r = ImageRenderer(content: view); r.scale = 2
            guard let cg = r.cgImage else { return XCTFail("렌더 실패 \(name)") }
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        for ms in [16, 80, 160, 240, 320, 420, 540, 680, 840, 1050] { save(String(format: "seq-%04d", ms), t: Double(ms) / 1000) }
        save("settled", t: 5)        // 무한대로 그리면 ImageRenderer 가 PlayOnChange 의 .task 를 돌려 첫 프레임이 타이핑 시작 상태로 찍힌다
    }
}
