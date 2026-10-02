import Foundation
import CoreGraphics

/// 펼침·접힘 애니메이션 규칙. 어떤 프레임에서도 섬이 접힘 크기보다 작아지면 안 된다 —
/// 작아지면 하드웨어 노치(카메라)가 드러난다. 접힘은 임계 감쇠(오버슈트 0), 펼침은 튕겨도 되지만 시작(접힘)보다 작아질 수 없다.
public enum IslandMotion {
    public static let closeResponse = 0.30
    public static let closeDamping = 1.0          // 임계 감쇠: 오버슈트 없음
    public static let openResponse = 0.46
    public static let openDamping = 0.78

    /// SwiftUI `.spring(response:dampingFraction:)` 와 같은 매개변수의 스텝 응답(0 → 1, 정지 상태에서 시작)
    public static func springProgress(t: Double, response: Double, damping z: Double) -> Double {
        guard t > 0 else { return 0 }
        let w = 2 * Double.pi / response
        if z >= 1 { return 1 - (1 + w * t) * exp(-w * t) }       // 임계 감쇠(z=1)
        let wd = w * (1 - z * z).squareRoot()
        return 1 - exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t))
    }

    /// 프레임마다 쓰는 안전장치: 곡선이 뭐든 접힘 크기 미만으로는 그리지 않는다.
    public static func clamped(_ v: CGFloat, min collapsed: CGFloat) -> CGFloat { max(v, collapsed) }
}
