import SwiftUI
import NotchIslandCore

extension Color {
    /// 시안의 oklch() 토큰을 그대로 옮기기 위한 변환. L 은 0...1, h 는 도(°).
    init(l: Double, c: Double, h: Double, a: Double = 1) {
        let hr = h * .pi / 180
        self.init(oklabL: l, a: c * cos(hr), b: c * sin(hr), alpha: a)
    }

    init(oklabL l: Double, a A: Double, b B: Double, alpha: Double = 1) {
        let l_ = l + 0.3963377774 * A + 0.2158037573 * B
        let m_ = l - 0.1055613458 * A - 0.0638541728 * B
        let s_ = l - 0.0894841775 * A - 1.2914855480 * B
        let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
        let r = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
        let g = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
        let bl = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S
        func enc(_ x: Double) -> Double {
            let v = max(0, min(1, x))
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        self.init(.sRGB, red: enc(r), green: enc(g), blue: enc(bl), opacity: alpha)
    }
}

/// 매트릭스(초록 인광) 한 벌. 상태 색은 정상=초록 · 주의=호박 · 높음=적주황이고, 색만으로 구분하지 않도록 단계마다 모양도 다르다.
struct ThemeStyle {
    let on: Color, on2: Color, on3: Color
    let hair: Color, hair2: Color
    let ok: Color, warn: Color, high: Color
    let accent: Color

    static let matrix: ThemeStyle = {
        let g = Color(l: 0.87, c: 0.17, h: 145)
        return ThemeStyle(on: g, on2: Color(l: 0.86, c: 0.13, h: 145), on3: Color(l: 0.78, c: 0.11, h: 145),
                          hair: Color(l: 0.88, c: 0.10, h: 145, a: 0.20), hair2: Color(l: 0.88, c: 0.10, h: 145, a: 0.30),
                          ok: g, warn: Color(l: 0.84, c: 0.15, h: 85), high: Color(l: 0.72, c: 0.20, h: 35),
                          accent: Color(l: 0.96, c: 0.07, h: 145))
    }()

    /// 0 정상 · 1 주의 · 2 높음 (열의 매우 높음도 색은 2)
    func color(forLevel lv: Int) -> Color { lv >= 2 ? high : lv == 1 ? warn : ok }

    func font(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// 단계별 모양: ◇ 정상 / ◈ 주의 / ◆ 높음 / ◉ 매우 높음(열만) / ✓ 회복.
    /// 열은 4단계(raw 0...3), 메모리는 3단계(raw 0...2) — 같은 모양표를 쓴다.
    static func glyph(raw: Int, recovered: Bool = false) -> String {
        if recovered { return "✓" }
        return ["◇", "◈", "◆", "◉"][min(max(raw, 0), 3)]
    }

    static let glyphChecking = "·"
}

private struct IslandReduceMotionKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// 시스템의 "동작 줄이기"(또는 검증용 강제값). 모든 뷰가 같은 값을 읽는다.
    var islandReduceMotion: Bool {
        get { self[IslandReduceMotionKey.self] }
        set { self[IslandReduceMotionKey.self] = newValue }
    }
}

/// 안 4(터미널 IDE) 카드 팔레트 — 시안 `.stage[data-v="4"]` 토큰 그대로(oklch). 본문 보조색 fg3 도 검정 위 대비 4.5:1 이상.
enum TermStyle {
    static let fg = Color(l: 0.91, c: 0.045, h: 145)
    static let fg2 = Color(l: 0.83, c: 0.075, h: 145)
    static let fg3 = Color(l: 0.72, c: 0.065, h: 145)
    static let acc = Color(l: 0.87, c: 0.17, h: 145)
    static let kw = Color(l: 0.87, c: 0.10, h: 115)           // 태그·포트·로그 단계(라임)
    static let rule = Color(l: 0.44, c: 0.065, h: 145)        // 창틀 선
    static let dim = Color(l: 0.34, c: 0.05, h: 145)          // 꺼진 칸·점
    static let segA = Color(l: 0.38, c: 0.08, h: 145)
    static let segB = Color(l: 0.29, c: 0.055, h: 145)
    static let segC = Color(l: 0.23, c: 0.035, h: 145)
    static let press = Color(l: 0.36, c: 0.06, h: 145)
    static let warn = ThemeStyle.matrix.warn
    static let high = ThemeStyle.matrix.high

    static func level(_ lv: Int) -> Color { lv >= 2 ? high : lv == 1 ? warn : acc }
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}
