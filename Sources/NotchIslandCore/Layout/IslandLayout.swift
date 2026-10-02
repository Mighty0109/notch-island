import Foundation
import CoreGraphics

/// 패널 안 좌표(왼쪽 위 원점)로 그린 섬 모양과 클릭·호버 판정 영역.
/// 뷰와 입력 처리가 같은 계산을 쓰므로 "그려진 곳 = 입력 받는 곳"이 구조적으로 맞는다.
public struct IslandLayout: Equatable {
    public static let panelWidth: CGFloat = 960
    public static let pillHeight: CGFloat = 40
    public static let pillGap: CGFloat = 12
    /// 알림 알약 모서리(안 4 시안 9pt — 캡슐이 아니라 둥근 사각)
    public static let pillCorner: CGFloat = 9

    /// 펼친 카드 폭(내용 기준, 안 4 시안 720). 접힌 폭보다 좁아지지는 않는다 — `openWidth` 참고
    public static let cardWidth: CGFloat = 720
    /// 카드가 가질 수 있는 최대 높이(패널 높이 산정용)
    public static let maxCardHeight: CGFloat = 560

    /// 날개 폭 한 쌍(왼쪽·오른쪽) — 각자 내용 폭 기준, 좌우 비대칭 허용
    public struct Wings: Equatable {
        public var left: CGFloat, right: CGFloat
        public init(left: CGFloat, right: CGFloat) { self.left = left; self.right = right }
    }

    public var phase: IslandPhase
    public var notchWidth: CGFloat
    public var notchHeight: CGFloat
    public var wingsCollapsed: Wings
    public var wingsOpen: Wings
    public var cardHeight: CGFloat
    public var pillWidth: CGFloat

    public init(phase: IslandPhase, notchWidth: CGFloat, notchHeight: CGFloat,
                wingsCollapsed: Wings = Wings(left: 70, right: 147), wingsOpen: Wings = Wings(left: 100, right: 270),
                cardHeight: CGFloat = 340, pillWidth: CGFloat = 320) {
        self.phase = phase; self.notchWidth = notchWidth; self.notchHeight = notchHeight
        self.wingsCollapsed = wingsCollapsed; self.wingsOpen = wingsOpen
        self.cardHeight = cardHeight; self.pillWidth = pillWidth
    }

    public static func panelHeight(notchHeight: CGFloat) -> CGFloat { notchHeight + maxCardHeight + 24 }

    /// 현재 단계의 날개 폭
    public var wings: Wings { phase.isOpen ? wingsOpen : wingsCollapsed }

    /// 카메라(노치 하드웨어) 중심 기준 섬의 왼쪽·오른쪽 뻗음 — 카메라 위치는 고정이고 섬이 한쪽만 길어질 수 있다.
    private var halfNotch: CGFloat { notchWidth / 2 }
    public var collapsedExtents: (left: CGFloat, right: CGFloat) { (halfNotch + wingsCollapsed.left, halfNotch + wingsCollapsed.right) }
    public var openExtents: (left: CGFloat, right: CGFloat) {
        // 카드 폭이 바닥: 머리줄이 좁은 쪽은 카드가 받쳐 준다(빈 검은 띠는 카드 안에서 내용이 채움)
        (max(halfNotch + wingsOpen.left, Self.cardWidth / 2), max(halfNotch + wingsOpen.right, Self.cardWidth / 2))
    }
    public var extents: (left: CGFloat, right: CGFloat) { phase.isOpen ? openExtents : collapsedExtents }

    /// 섬 외곽의 접힘·펼침 끝값(애니메이션 입력). 펼침 머리줄 뻗음 = 카메라 반폭 + 펼침 날개.
    public var shape: IslandShape {
        IslandShape(collapsedLeft: Double(collapsedExtents.left), collapsedRight: Double(collapsedExtents.right), collapsedHeight: Double(notchHeight),
                    openLeft: Double(openExtents.left), openRight: Double(openExtents.right), openHeight: Double(notchHeight + cardHeight),
                    headOpenLeft: Double(halfNotch + wingsOpen.left), headOpenRight: Double(halfNotch + wingsOpen.right))
    }

    /// 접힌 섬 폭 — 노치 + 각자 날개
    public var collapsedWidth: CGFloat { notchWidth + wingsCollapsed.left + wingsCollapsed.right }
    public var openHeadWidth: CGFloat { notchWidth + wingsOpen.left + wingsOpen.right }
    public var openWidth: CGFloat { openExtents.left + openExtents.right }

    /// 머리줄(왼쪽 날개 · 카메라 · 오른쪽 날개)의 자리. 카메라는 늘 같은 자리(패널 가운데)이고 날개만 각자 폭으로 늘고 준다.
    public var head: CGRect {
        let w = wings
        return CGRect(x: Self.panelWidth / 2 - halfNotch - w.left, y: 0, width: notchWidth + w.left + w.right, height: notchHeight)
    }

    /// 섬 안에서 머리줄 왼쪽 끝의 x (접힘이면 0)
    public var headXInIsland: CGFloat { extents.left - halfNotch - wings.left }

    /// 섬 본체 사각형
    public var island: CGRect {
        let e = extents
        return CGRect(x: Self.panelWidth / 2 - e.left, y: 0, width: e.left + e.right,
                      height: phase.isOpen ? notchHeight + cardHeight : notchHeight)
    }

    /// 물방울 알약(알림 중에만)
    public var pill: CGRect? {
        guard phase == .alert else { return nil }
        let cx = Self.panelWidth / 2
        return CGRect(x: cx - pillWidth / 2, y: notchHeight + Self.pillGap, width: pillWidth, height: Self.pillHeight)
    }

    /// 입력 판정: 그려진 영역만 받는다. 나머지는 nil 이 아니라 `.none` → 패널이 클릭을 통과시킨다.
    public func zone(at p: CGPoint) -> PointerZone {
        guard phase != .hidden else { return .none }
        if let pill, pill.insetBy(dx: -2, dy: -2).contains(p) { return .pill }
        guard island.contains(p) else { return .none }
        if phase.isOpen { return p.y < notchHeight ? .head : .card }
        return .head
    }
}
