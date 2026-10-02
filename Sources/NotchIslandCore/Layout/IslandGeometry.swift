import Foundation
import CoreGraphics

/// 섬 외곽 모양의 양 끝값(카메라 중심 기준 왼쪽·오른쪽 뻗음, 높이)과 머리줄 날개 뻗음. 접힘 = 머리줄 그대로, 펼침 = 카드가 받친 큰 모양.
public struct IslandShape: Equatable {
    public var collapsedLeft: Double, collapsedRight: Double, collapsedHeight: Double
    public var openLeft: Double, openRight: Double, openHeight: Double
    public var headOpenLeft: Double, headOpenRight: Double        // 펼친 머리줄의 카메라 기준 뻗음(접힘 머리줄 뻗음 = collapsedLeft/Right)

    public init(collapsedLeft: Double, collapsedRight: Double, collapsedHeight: Double,
                openLeft: Double, openRight: Double, openHeight: Double, headOpenLeft: Double, headOpenRight: Double) {
        self.collapsedLeft = collapsedLeft; self.collapsedRight = collapsedRight; self.collapsedHeight = collapsedHeight
        self.openLeft = openLeft; self.openRight = openRight; self.openHeight = openHeight
        self.headOpenLeft = headOpenLeft; self.headOpenRight = headOpenRight
    }

    /// 애니메이션용 벡터(앞 8개)
    public var packed: [Double] {
        [collapsedLeft, collapsedRight, collapsedHeight, openLeft, openRight, openHeight, headOpenLeft, headOpenRight]
    }
    public init(packed v: [Double]) {
        self.init(collapsedLeft: v[0], collapsedRight: v[1], collapsedHeight: v[2], openLeft: v[3], openRight: v[4], openHeight: v[5],
                  headOpenLeft: v[6], headOpenRight: v[7])
    }
}

/// 한 프레임의 섬 끝값. `progress` 0 = 접힘, 1 = 펼침(펼침 튕김은 1 을 넘을 수 있다).
public struct IslandEnds: Equatable {
    public var left: Double, right: Double, height: Double
    public var headLeft: Double, headRight: Double        // 머리줄 카메라 기준 뻗음 — 항상 섬 안
    public var radius: Double
}

/// **끝마다** 접힘 값 ↔ 펼침 값을 하나의 진행도(p)로 단조 보간한다. p 는 0 미만으로 못 내려가므로(닫힘은 임계 감쇠라 p 가 0 으로 단조 감소)
/// 어떤 프레임에서도 왼쪽 끝 ≤ 접힘 왼쪽 끝, 오른쪽 끝 ≥ 접힘 오른쪽 끝, 높이 ≥ 접힘 높이이고, 머리줄은 섬 사각형 안에 있다.
/// (예전엔 좌·우·높이를 각자 애니메이션하고 머리줄 위치를 따로 보간해, 비대칭 접힘 섬에서 왼쪽 끝이 접힘 머리줄 안으로 들어와 CPU 칸을 잘라 먹었다.)
public enum IslandGeometry {
    public static let collapsedRadius = 12.0, openRadius = 28.0

    public static func ends(_ s: IslandShape, progress: Double) -> IslandEnds {
        let p = max(0, progress)
        // 펼침 쪽 끝은 접힘 끝·머리줄 끝보다 작을 수 없다(방어)
        let oL = max(s.openLeft, s.headOpenLeft, s.collapsedLeft), oR = max(s.openRight, s.headOpenRight, s.collapsedRight)
        let hoL = max(s.headOpenLeft, s.collapsedLeft), hoR = max(s.headOpenRight, s.collapsedRight)
        let oH = max(s.openHeight, s.collapsedHeight)
        func lerp(_ c: Double, _ o: Double) -> Double { c + (o - c) * p }
        return IslandEnds(left: lerp(s.collapsedLeft, oL), right: lerp(s.collapsedRight, oR), height: lerp(s.collapsedHeight, oH),
                          headLeft: lerp(s.collapsedLeft, hoL), headRight: lerp(s.collapsedRight, hoR),
                          radius: lerp(collapsedRadius, openRadius))
    }
}
