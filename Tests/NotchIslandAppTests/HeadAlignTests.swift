import XCTest
import SwiftUI
import AppKit
@testable import NotchIsland
import NotchIslandCore

/// 펼침 머리줄 정렬: 왼쪽 날개 내용은 섬 왼쪽 바깥 끝 + 날개 여백(14), 오른쪽 날개 내용은 오른쪽 바깥 끝 − 14 에 붙는다(링 없음/있음 모두).
/// 빈 공간은 카메라 쪽으로 모인다. 접힘은 날개 = 내용 폭이라 여백(10)만큼 안쪽.
@MainActor
final class HeadAlignTests: XCTestCase {
    private func makeModel(job: Bool) -> IslandModel {
        let suite = "com.mighty.notch-island.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        let s = SettingsStore(defaults: d)
        s.hoverExpand = false
        let m = IslandModel(settings: s)
        if job { m.debugToggleCharging() }
        return m
    }

    /// 머리줄(섬 가로 전체)을 NSHostingView 로 띄워 좌우 내용의 바깥 끝을 잰다. 반환 = (왼쪽 첫 칸 minX, 오른쪽 끝 maxX, 머리줄 폭)
    private func measure(_ model: IslandModel, progress: Double) -> (CGFloat, CGFloat, CGFloat) {
        let layout = model.layout
        let e = IslandGeometry.ends(layout.shape, progress: progress)
        let w = CGFloat(e.left + e.right)
        var edges = HeadEdges()
        let root = HeadStrip(model: model, wingLeft: CGFloat(e.left) - layout.notchWidth / 2, wingRight: CGFloat(e.right) - layout.notchWidth / 2, notchWidth: layout.notchWidth)
            .frame(width: w, height: layout.notchHeight, alignment: .topLeading)
            .onPreferenceChange(HeadEdgesKey.self) { edges = $0 }
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: w, height: layout.notchHeight)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        return (edges.leftMinX ?? -1, edges.rightMaxX ?? -1, w)
    }

    func testOpenLeftContentHugsIslandLeftEdgeAndRightContentHugsRightEdge() {
        for job in [false, true] {
            let m = makeModel(job: job)
            m.click(.head)
            XCTAssertEqual(m.phase, .pinned)
            XCTAssertEqual(m.memorySide, job ? .left : .right, "링 있음 = 메모리 왼쪽(접힘 판정 그대로)")
            let pad = Double(HeadSpacing.open.wingPad)
            let (l, r, w) = measure(m, progress: 1)
            XCTAssertEqual(Double(l), pad, accuracy: 1, "링 \(job ? "있음" : "없음"): 왼쪽 첫 칸 x = 섬 왼끝 + \(pad)")
            XCTAssertEqual(Double(w - r), pad, accuracy: 1, "링 \(job ? "있음" : "없음"): 오른쪽 끝 = 섬 오른끝 − \(pad)")
            // 빈 공간은 카메라 쪽: 왼쪽 내용 끝은 카메라 왼쪽 끝 전, 오른쪽 내용 시작은 카메라 오른쪽 끝 뒤
        }
    }

    /// 접힘도 같은 규칙(여백 10): 날개 = 내용 폭 + 여백이라 바깥 끝에 붙어 있다
    func testCollapsedStripSitsAtOuterEdgesWithCollapsedPad() {
        for job in [false, true] {
            let m = makeModel(job: job)
            let pad = Double(HeadSpacing.collapsed.wingPad)
            let (l, r, w) = measure(m, progress: 0)
            XCTAssertEqual(Double(l), pad, accuracy: 1.5, "접힘(링 \(job)): 왼쪽 첫 칸")
            XCTAssertEqual(Double(w - r), pad, accuracy: 1.5, "접힘(링 \(job)): 오른쪽 끝")
        }
    }
}
