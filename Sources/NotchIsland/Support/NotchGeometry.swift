import AppKit

/// 내장 노치 화면의 실제 치수. `safeAreaInsets`/`auxiliaryTopLeftArea·RightArea` 로 계산한다.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var centerX: CGFloat            // 화면(전역) 좌표계의 노치 중심 x
    var displayID: CGDirectDisplayID?

    /// 노치가 있는 화면. 없으면 nil (외장 모니터 가짜 알약은 v0.1 범위 밖).
    static func current() -> NotchGeometry? {
        for s in NSScreen.screens {
            guard s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { continue }
            let width = r.minX - l.maxX
            guard width > 40 else { continue }
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            return NotchGeometry(screenFrame: s.frame, notchWidth: width, notchHeight: s.safeAreaInsets.top,
                                 centerX: (l.maxX + r.minX) / 2, displayID: id)   // 보조 영역은 frame 과 같은 전역 좌표
        }
        return nil
    }
}
