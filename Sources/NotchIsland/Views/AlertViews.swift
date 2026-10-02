import SwiftUI
import NotchIslandCore

/// 물방울 알림: 노치에서 검은 방울이 떨어져 알약으로 펴지고, 끝나면 다시 빨려 들어간다.
/// 도형은 goo(블러 + 알파 임계) 레이어로, 글자는 그 위 별도 레이어로 그려 글자가 흐려지지 않는다.
struct DropLayer: View {
    @ObservedObject var model: IslandModel
    let layout: IslandLayout

    var body: some View {
        let animating = model.drop == .falling || model.drop == .retract
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animating)) { tl in
            let p = progress(now: tl.date)
            Canvas { ctx, size in
                ctx.addFilter(.alphaThreshold(min: 0.5, color: .black))
                ctx.addFilter(.blur(radius: 5))
                ctx.drawLayer { l in
                    let cx = IslandLayout.panelWidth / 2
                    let nh = layout.notchHeight
                    l.fill(Path(CGRect(x: cx - 60, y: -12, width: 120, height: nh + 12)), with: .color(.black))
                    let r = frame(at: p, pillW: layout.pillWidth, notchH: nh)
                    // 방울 → 알약으로 펴지는 동안은 둥글고, 다 펴지면 시안(안 4)처럼 모서리 9pt 사각 알약
                    let settle = max(0, min(1, (p - 0.72) / 0.28))
                    let radius = min(r.width, r.height) / 2 * (1 - settle) + IslandLayout.pillCorner * settle
                    l.fill(Path(roundedRect: r, cornerRadius: radius), with: .color(.black))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func progress(now: Date) -> Double {
        let e = now.timeIntervalSince(model.dropStartedAt)
        switch model.drop {
        case .falling: return min(1, e / 0.78)
        case .retract: return max(0, 1 - e * 1.3 / 0.78)
        default: return 1
        }
    }

    /// 시안의 키프레임(0 / .26 / .5 / .72 / 1)을 노치 높이에 맞춰 옮긴 것
    private func frame(at p: Double, pillW: CGFloat, notchH nh: CGFloat) -> CGRect {
        let cx = IslandLayout.panelWidth / 2
        let pillTop = nh + IslandLayout.pillGap
        let frames: [(Double, CGRect)] = [
            (0.00, CGRect(x: cx - 14, y: nh - 28, width: 28, height: 24)),
            (0.26, CGRect(x: cx - 13, y: nh - 14, width: 26, height: 44)),
            (0.50, CGRect(x: cx - 11, y: nh + 12, width: 22, height: 34)),
            (0.72, CGRect(x: cx - 12, y: nh + 28, width: 24, height: 24)),
            (1.00, CGRect(x: cx - pillW / 2, y: pillTop, width: pillW, height: IslandLayout.pillHeight)),
        ]
        var i = 0
        while i < frames.count - 2, p > frames[i + 1].0 { i += 1 }
        let a = frames[i], b = frames[i + 1]
        let u = max(0, min(1, (p - a.0) / (b.0 - a.0)))
        let e = u * u * (3 - 2 * u)
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * CGFloat(e) }
        return CGRect(x: mix(a.1.minX, b.1.minX), y: mix(a.1.minY, b.1.minY), width: mix(a.1.width, b.1.width), height: mix(a.1.height, b.1.height))
    }
}

/// 알약 위 글자 레이어(필터 밖). 알약이 완성되면 글자를 가로로 잘라 0.2초 흔들고(덧칠 층 없음 — 글자 자체가 잘린다),
/// 문구가 블록 커서와 함께 타이핑되며 가타카나에서 진짜 글자로 굳는다. 끝나면 시계가 멈춘다. 클릭 = 고정 펼침.
struct PillText: View {
    @ObservedObject var model: IslandModel
    let layout: IslandLayout
    @State private var running = true

    var body: some View {
        let show = model.drop == .pill
        let lv = model.event?.level ?? 0
        let pill = layout.pill ?? .zero
        let chars = model.alertText.count + 2          // "◆ " + 문구
        let animate = show && running && !model.reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animate)) { tl in
            let e: Double = animate ? tl.date.timeIntervalSince(model.dropStartedAt) : .infinity
            TypedLine(segs: [TermSeg(ThemeStyle.glyph(raw: lv) + " ", TermStyle.level(lv), .bold), TermSeg(model.alertText, TermStyle.fg, .semibold)],
                      size: 13, elapsed: e, cps: RevealTiming.pillCharsPerSecond, caret: TermStyle.acc)
                .modifier(GlitchSlice(step: RevealTiming.glitchStep(elapsed: e)))
                .frame(width: model.pillTextWidth, height: pill.height, alignment: .leading)
        }
        .frame(width: pill.width, height: pill.height)
        .background(
            RoundedRectangle(cornerRadius: IslandLayout.pillCorner, style: .continuous).fill(Color.black)
                .opacity(model.reduceMotion || show ? 1 : 0)      // 물방울 도형이 사라진 뒤에도 알약이 남게 평평한 바탕을 깐다
        )
        .position(x: pill.midX, y: pill.midY)
        .opacity(show ? 1 : 0)
        .animation(.linear(duration: show ? 0.2 : 0.12), value: show)
        .contentShape(Rectangle())
        .onTapGesture { model.click(.pill) }
        .allowsHitTesting(show)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.alertText)
        .accessibilityHidden(!show)
        .task(id: model.dropStartedAt) {
            running = true
            guard show, !model.reduceMotion else { running = false; return }
            try? await Task.sleep(nanoseconds: UInt64(RevealTiming.pillTotal(chars: chars) * 1_000_000_000))
            running = false
        }
    }
}
