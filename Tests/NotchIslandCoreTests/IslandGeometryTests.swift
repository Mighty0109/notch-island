import XCTest
@testable import NotchIslandCore

/// 섬 외곽 닫힘·펼침: 왼쪽 끝·오른쪽 끝·아래 끝이 각각 단조이고 접힘 끝 안쪽으로 한 프레임도 안 들어오며, 머리줄은 늘 섬 안이다.
/// (2026-10-03 마이티 화면 녹화: 닫힐 때 왼쪽 가장자리가 접힘 머리줄의 CPU 칸을 잘라 먹었다 — 이전의 "폭 합계 ≥ 접힘" 검사는 이걸 못 잡았다)
final class IslandGeometryTests: XCTestCase {
    /// 실제 레이아웃 계산으로 만든 섬 모양들: 노치 폭 · 비대칭 날개(접힘/펼침) · 카드 높이 · 카드가 받치는 경우/머리줄이 더 넓은 경우
    private func shapes() -> [(String, IslandShape)] {
        var out: [(String, IslandShape)] = []
        let wingSets: [(IslandLayout.Wings, IslandLayout.Wings)] = [
            (.init(left: 52, right: 110), .init(left: 90, right: 190)),      // 비대칭, 카드가 받침
            (.init(left: 118, right: 60), .init(left: 160, right: 150)),
            (.init(left: 60, right: 60), .init(left: 300, right: 420)),      // 펼친 머리줄이 카드(720)보다 넓음
            (.init(left: 40, right: 200), .init(left: 40, right: 200)),      // 접힘 = 펼침 날개
        ]
        for nw in [185, 250] as [CGFloat] {
            for (i, w) in wingSets.enumerated() {
                let l = IslandLayout(phase: .pinned, notchWidth: nw, notchHeight: 43, wingsCollapsed: w.0, wingsOpen: w.1, cardHeight: 426)
                out.append(("nw\(Int(nw)) wings#\(i)", l.shape))
            }
        }
        return out
    }

    private func sequence(closing: Bool, response: Double, damping: Double, from p0: Double = 1) -> [Double] {
        (0...1500).map { i in
            let s = IslandMotion.springProgress(t: Double(i) / 1000, response: response, damping: damping)
            return closing ? p0 * (1 - s) : p0 + (1 - p0) * s
        }
    }

    private func check(_ name: String, _ shape: IslandShape, _ ps: [Double], overshootOK: Bool) {
        var prev: IslandEnds?
        for (i, p) in ps.enumerated() {
            let e = IslandGeometry.ends(shape, progress: p)
            XCTAssertGreaterThanOrEqual(e.left, shape.collapsedLeft - 1e-9, "\(name) #\(i): 왼쪽 끝이 접힘 왼쪽 끝 안쪽으로 들어옴")
            XCTAssertGreaterThanOrEqual(e.right, shape.collapsedRight - 1e-9, "\(name) #\(i): 오른쪽 끝이 접힘 오른쪽 끝 안쪽")
            XCTAssertGreaterThanOrEqual(e.height, shape.collapsedHeight - 1e-9, "\(name) #\(i): 높이가 접힘 높이 미만")
            // 머리줄 ⊂ 섬: 머리줄 양쪽 끝이 섬 끝 안, 접힘 머리줄보다 작지도 않다(접힘 머리줄은 닫힘 내내 그대로 보인다)
            XCTAssertLessThanOrEqual(e.headLeft, e.left + 1e-9, "\(name) #\(i): 머리줄 왼쪽이 섬 밖(잘림)")
            XCTAssertLessThanOrEqual(e.headRight, e.right + 1e-9, "\(name) #\(i): 머리줄 오른쪽이 섬 밖(잘림)")
            XCTAssertGreaterThanOrEqual(e.headLeft, shape.collapsedLeft - 1e-9); XCTAssertGreaterThanOrEqual(e.headRight, shape.collapsedRight - 1e-9)
            XCTAssertLessThanOrEqual(43, e.height + 1e-9, "머리줄 높이가 섬 안")
            if let q = prev, !overshootOK {      // 닫힘: 세 끝이 각각 단조 감소(= 접힘 쪽으로만)
                XCTAssertLessThanOrEqual(e.left, q.left + 1e-9, "\(name) #\(i): 왼쪽 끝이 다시 커짐"); XCTAssertLessThanOrEqual(e.right, q.right + 1e-9)
                XCTAssertLessThanOrEqual(e.height, q.height + 1e-9); XCTAssertLessThanOrEqual(e.headLeft, q.headLeft + 1e-9)
            }
            prev = e
        }
    }

    func testClosingEachEdgeIsMonotoneAndNeverInsideCollapsedEdges() {
        for (name, s) in shapes() {
            for p0 in [1.0, 0.7, 0.3] {      // 끝까지 펼친 뒤·펼치는 도중에 닫혀도
                check("\(name) close p0=\(p0)", s, sequence(closing: true, response: IslandMotion.closeResponse, damping: IslandMotion.closeDamping, from: p0), overshootOK: false)
            }
        }
    }

    /// 펼침도 같은 원칙: 시작(접힘) 끝값 안쪽으로 안 들어오고, 튕겨도 펼침 끝값을 조금 넘을 뿐이다
    func testOpeningNeverGoesInsideCollapsedEdgesAndBounceOnlyOvershoots() {
        for (name, s) in shapes() {
            check("\(name) open", s, sequence(closing: false, response: IslandMotion.openResponse, damping: IslandMotion.openDamping, from: 0), overshootOK: true)
            let peak = IslandGeometry.ends(s, progress: sequence(closing: false, response: IslandMotion.openResponse, damping: IslandMotion.openDamping, from: 0).max()!)
            XCTAssertGreaterThanOrEqual(peak.left, s.openLeft - 1e-9, "펼침 튕김은 목표를 넘는 쪽으로만")
        }
    }

    func testEndpointsMatchLayoutAndHeadStaysInsideIslandAtRest() {
        for nw in [185, 250] as [CGFloat] {
            let l = IslandLayout(phase: .pinned, notchWidth: nw, notchHeight: 43, wingsCollapsed: .init(left: 52, right: 110), wingsOpen: .init(left: 90, right: 190), cardHeight: 426)
            let c = IslandGeometry.ends(l.shape, progress: 0), o = IslandGeometry.ends(l.shape, progress: 1)
            XCTAssertEqual(c.left, Double(l.collapsedExtents.left)); XCTAssertEqual(c.right, Double(l.collapsedExtents.right)); XCTAssertEqual(c.height, 43)
            XCTAssertEqual(c.headLeft, c.left, "접힘: 머리줄 = 섬 전체"); XCTAssertEqual(c.headRight, c.right)
            XCTAssertEqual(o.left, Double(l.openExtents.left)); XCTAssertEqual(o.right, Double(l.openExtents.right)); XCTAssertEqual(o.height, 43 + 426)
            XCTAssertEqual(o.headLeft, Double(nw / 2 + 90)); XCTAssertEqual(o.headRight, Double(nw / 2 + 190))
            XCTAssertGreaterThanOrEqual(o.left, 360); XCTAssertGreaterThanOrEqual(o.right, 360)        // 카드(720)가 카메라 중심으로 섬 안
        }
    }

    /// 방어: 펼침 쪽 값이 접힘보다 작게 들어와도(예: 날개가 줄어든 채 펼침) 접힘 끝 안쪽으로는 안 간다
    func testDegenerateOpenShapeStillRespectsCollapsedEdges() {
        let s = IslandShape(collapsedLeft: 200, collapsedRight: 300, collapsedHeight: 43, openLeft: 100, openRight: 100, openHeight: 20, headOpenLeft: 50, headOpenRight: 50)
        for p in stride(from: -0.5, through: 1.5, by: 0.05) {
            let e = IslandGeometry.ends(s, progress: p)
            XCTAssertGreaterThanOrEqual(e.left, 200); XCTAssertGreaterThanOrEqual(e.right, 300); XCTAssertGreaterThanOrEqual(e.height, 43)
            XCTAssertLessThanOrEqual(e.headLeft, e.left); XCTAssertLessThanOrEqual(e.headRight, e.right)
        }
    }

    func testPackedRoundTrip() {
        let s = IslandShape(collapsedLeft: 1, collapsedRight: 2, collapsedHeight: 3, openLeft: 4, openRight: 5, openHeight: 6, headOpenLeft: 7, headOpenRight: 8)
        XCTAssertEqual(IslandShape(packed: s.packed), s)
    }

    func testCloseDelayLeavesTimeForTheCardToFadeFirst() {
        XCTAssertEqual(IslandMotion.closeDelay, 0.12, accuracy: 1e-9)
    }
}
