import AppKit

/// 메뉴바 아이콘·앱 아이콘 글리프. 외부 에셋 없이 코드로 그린다 (벡터 → @1x/@2x 모두 선명).
/// 세 후보를 함께 두어 교체가 한 줄로 끝나게 했다. 비교 시트·.icns 는 `scripts/logo-assets.sh` 가 이 파일을 그대로 컴파일해 만든다.
/// 이 파일은 AppKit 만 의존한다 — 스크립트에서 단독 컴파일되므로 다른 앱 소스를 import 하지 말 것.
enum LogoImage {
    /// 메뉴바에 쓰는 후보. 그림은 18×18pt 좌표계(왼쪽 위 원점, 정수 격자)로 그린다.
    enum Candidate: String, CaseIterable {
        /// 화면 윗선 + 노치 + 양옆 상태 막대(날개). "노치 옆에 값이 뜬다"는 앱 동작 그대로.
        case wings
        /// 화면 윗선 + 노치, 노치 안에 프롬프트 밑줄 커서 `_` 를 뚫음. 터미널 정체성.
        case cursor
        /// 화면 윗선 + 노치, 노치 밑으로 떨어지는 코드 비 세 줄. 매트릭스 정체성.
        case rain

        var title: String {
            switch self {
            case .wings: return "A · 노치 + 날개"
            case .cursor: return "B · 노치 + 커서"
            case .rain: return "C · 노치 + 코드 비"
            }
        }
    }

    /// 앱이 실제로 쓰는 후보. 바꾸려면 이 한 줄.
    static let current: Candidate = .rain

    /// 메뉴바용 템플릿 이미지(단색·알파만 사용, 시스템이 다크/라이트에 맞춰 칠한다).
    static func menuBarImage(_ candidate: Candidate = current) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            drawGlyph(candidate, in: rect, color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Notch Island"
        return image
    }

    /// 글리프를 `rect` 에 맞춰 그린다 (18×18 좌표계를 rect 로 확대). 좌표계는 왼쪽 위 원점(flipped).
    static func drawGlyph(_ candidate: Candidate, in rect: CGRect, color: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / 18, y: rect.height / 18)
        color.setFill()
        glyphPath(candidate).fill()
        ctx.restoreGState()
    }

    /// 18×18 좌표계의 채움 경로. 가로·세로 모서리는 전부 정수(또는 .5)에 두어 @1x 에서도 번지지 않는다.
    static func glyphPath(_ candidate: Candidate) -> NSBezierPath {
        let path = NSBezierPath()
        path.windingRule = .evenOdd

        // 공통: 화면 윗선(가로 1pt) — 노치가 "화면 위에서 내려온 것"으로 읽히게 한다.
        func topLine(y: CGFloat) { path.appendRect(CGRect(x: 1, y: y, width: 16, height: 1)) }
        // 공통: 노치 — 윗선에 붙어 아래로 내려오고 아래 두 모서리만 둥글다.
        func notch(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat) {
            let p = NSBezierPath()
            p.move(to: CGPoint(x: x, y: y))
            p.line(to: CGPoint(x: x + w, y: y))
            p.line(to: CGPoint(x: x + w, y: y + h - r))
            p.appendArc(withCenter: CGPoint(x: x + w - r, y: y + h - r), radius: r, startAngle: 0, endAngle: 90, clockwise: false)
            p.line(to: CGPoint(x: x + r, y: y + h))
            p.appendArc(withCenter: CGPoint(x: x + r, y: y + h - r), radius: r, startAngle: 90, endAngle: 180, clockwise: false)
            p.close()
            path.append(p)
        }
        func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat = 0) {
            let r = CGRect(x: x, y: y, width: w, height: h)
            path.append(radius > 0 ? NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) : NSBezierPath(rect: r))
        }

        // 노치는 실물처럼 넓고 얕게(10×4) — 깊으면 18pt 에서 컵·샤워기로 읽힌다(1차 시트에서 확인).
        switch candidate {
        case .wings:
            topLine(y: 4)
            notch(x: 4, y: 5, w: 10, h: 4, r: 2)   // 윗선 바로 아래부터(겹치면 evenOdd 로 뚫린다)
            bar(1, 6, 2, 2)               // 왼쪽 날개(CPU 값 자리) — 2×2 는 둥글리면 @1x 에서 회색이 된다
            bar(15, 6, 2, 2)              // 오른쪽 날개(메모리 값 자리)
            bar(4, 11, 10, 3, radius: 1.5) // 노치 밑으로 내려온 카드(펼침)
        case .cursor:
            topLine(y: 4)
            notch(x: 4, y: 5, w: 10, h: 4, r: 2)
            bar(7, 11, 4, 2)              // 노치 밑에서 깜빡이는 프롬프트 커서 `_`
        case .rain:
            topLine(y: 2)
            notch(x: 4, y: 3, w: 10, h: 4, r: 2)
            bar(5, 9, 2, 4)               // 코드 비 — 길이가 다른 세 줄, 가운데는 끊긴 줄. 각진 블록 글자 느낌 + @1x 선명
            bar(8, 9, 2, 2)
            bar(8, 12, 2, 4)
            bar(11, 9, 2, 3)
        }
        return path
    }

    // MARK: 앱 아이콘(.icns 재료)

    /// 1024 기준 앱 아이콘 한 장: 둥근 사각 어두운 바탕 + 초록 인광 글리프. `scale` 로 다른 크기를 만든다.
    static func drawAppIcon(_ candidate: Candidate = current, side: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = side / 1024
        // macOS 아이콘 규격: 1024 캔버스에 824 둥근 사각(모서리 ≈ 185), 바깥은 투명.
        let plate = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let plateRadius = 185 * s
        let platePath = NSBezierPath(roundedRect: plate, xRadius: plateRadius, yRadius: plateRadius)

        // 바탕: 아주 어두운 녹흑 그라데이션(위가 조금 밝다).
        let top = NSColor(srgbRed: 0.055, green: 0.090, blue: 0.070, alpha: 1)
        let bottom = NSColor(srgbRed: 0.020, green: 0.035, blue: 0.028, alpha: 1)
        NSGradient(starting: top, ending: bottom)?.draw(in: platePath, angle: -90)

        // 글리프 색: 앱 ThemeStyle 의 초록(oklch 0.87/0.17/145)에 가까운 sRGB.
        let green = NSColor(srgbRed: 0.33, green: 0.95, blue: 0.53, alpha: 1)
        let glyphRect = CGRect(x: 192 * s, y: 192 * s, width: 640 * s, height: 640 * s)

        // 인광: 같은 글리프를 큰 블러 그림자로 두 번 깐다.
        ctx.saveGState()
        platePath.addClip()
        for (blur, alpha) in [(70 * s, 0.55), (22 * s, 0.9)] {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: blur, color: green.withAlphaComponent(alpha).cgColor)
            drawGlyph(candidate, in: glyphRect, color: green)
            ctx.restoreGState()
        }
        drawGlyph(candidate, in: glyphRect, color: green)
        ctx.restoreGState()

        // 테두리 하이라이트 1px — 어두운 독에서 바탕과 분리.
        ctx.saveGState()
        green.withAlphaComponent(0.25).setStroke()
        platePath.lineWidth = max(1, 3 * s)
        platePath.stroke()
        ctx.restoreGState()
    }
}
