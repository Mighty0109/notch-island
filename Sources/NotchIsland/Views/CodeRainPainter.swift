import SwiftUI

/// 코드 비 한 프레임을 그린다(펼친 뒤 약 0.95초만). 모양·속도·투명도 계산은 그대로이고, 그리는 방식만 바꿨다:
/// 예전엔 글자 하나마다 `Text` 를 새로 resolve 했다(프레임당 최대 ~540번) — 프로파일(2026-10-03)에서 섬을 열 때마다 메인 스레드 CPU 의 절반(360/647ms)이었다.
/// 지금은 프레임마다 문자별로 한 번만 resolve 해 재사용하고, 투명도는 그리는 컨텍스트의 `opacity` 로 준다(같은 알파 합성).
enum CodeRainPainter {
    static let duration = 0.95
    static let glyphs = Array("0123456789ABCDEFｱｲｳｴｵｶｷｸｹｺ")
    private static let font = Font.system(size: 11, design: .monospaced)

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double, color: Color) {
        guard t >= 0, t < duration else { return }
        let fade = 1 - max(0, (t - 0.45) / 0.5)
        let colW: CGFloat = 12, rowH: CGFloat = 13
        let cols = Int(size.width / colW)
        var resolved = [GraphicsContext.ResolvedText?](repeating: nil, count: glyphs.count)
        for c in 0..<cols {
            let seed = Double((c * 7919) % 97) / 97
            let speed = 320 + seed * 260
            let head = (t * speed + seed * 220).truncatingRemainder(dividingBy: Double(size.height + 160)) - 40
            for k in 0..<9 {
                let y = head - Double(k) * Double(rowH)
                guard y > -rowH, y < Double(size.height) else { continue }
                let gi = (c * 3 + k * 5 + Int(t * 22)) % glyphs.count
                let a = (k == 0 ? 1.0 : max(0.05, 0.8 - Double(k) * 0.1)) * fade
                let text: GraphicsContext.ResolvedText
                if let r = resolved[gi] { text = r } else {
                    text = ctx.resolve(Text(String(glyphs[gi])).font(font).foregroundColor(color))
                    resolved[gi] = text
                }
                ctx.opacity = a
                ctx.draw(text, at: CGPoint(x: CGFloat(c) * colW + colW / 2, y: CGFloat(y)))
            }
        }
    }
}
