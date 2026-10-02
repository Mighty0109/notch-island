import SwiftUI
import NotchIslandCore

// 안 4(터미널 + 매트릭스) 카드를 이루는 작은 부품들. 계산(타이밍·가타카나·로그 문구)은 Core 에 있고 여기는 그리기만 한다.

/// 한 줄을 이루는 같은 색 글자 조각
struct TermSeg: Equatable {
    let text: String
    let color: Color
    var weight: Font.Weight = .regular
    init(_ text: String, _ color: Color, _ weight: Font.Weight = .regular) { self.text = text; self.color = color; self.weight = weight }
}

/// 타이핑 + 해독 한 줄. `elapsed` = 이 줄이 시작한 뒤 지난 초(무한대 = 연출 없이 그냥 표시).
/// 드러난 글자는 0.14초 동안 가타카나였다가 진짜 글자로 굳는다. 안 드러난 글자는 **투명으로 자리만** 잡는다(줄 폭이 안 변해 글자가 안 밀린다).
/// 글자 위에 겹치는 층은 없다 — 글자 자체가 바뀔 뿐이다.
struct TypedLine: View {
    let segs: [TermSeg]
    var size: CGFloat = 12
    var elapsed: Double = .infinity
    var cps: Double = RevealTiming.cardCharsPerSecond
    var caret: Color?                       // 타이핑 앞쪽 블록 커서(알림 문구). 끝나면 잠깐 깜빡이다 사라진다.

    /// 입력이 같으면 글자를 다시 만들지 않는다(`.equatable()`) — 카드는 1초마다 통째로 다시 평가되는데 대부분의 줄(머리·라벨·llm·로그)은 안 바뀐다.
    /// 이게 없으면 줄마다 AttributedString 을 다시 만들어 SwiftUI 가 글자를 다시 해석한다(펼침 고정 idle 실측 +1.3%p).
    var body: some View {
        TypedLineText(segs: segs, size: size, elapsed: elapsed, cps: cps, caret: caret).equatable()
    }

    static func attributed(segs: [TermSeg], size: CGFloat, elapsed: Double, cps: Double, caret: Color?) -> AttributedString {
        TypedLineText.attributed(segs: segs, size: size, elapsed: elapsed, cps: cps, caret: caret)
    }
}

struct TypedLineText: View, Equatable {
    let segs: [TermSeg]
    let size: CGFloat
    let elapsed: Double
    let cps: Double
    let caret: Color?

    var body: some View {
        Text(Self.attributed(segs: segs, size: size, elapsed: elapsed, cps: cps, caret: caret))
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }

    static func attributed(segs: [TermSeg], size: CGFloat, elapsed: Double, cps: Double, caret: Color?) -> AttributedString {
        func piece(_ s: String, _ color: Color, _ w: Font.Weight) -> AttributedString {
            var a = AttributedString(s); a.foregroundColor = color; a.font = TermStyle.font(size, w); return a
        }
        let total = segs.reduce(0) { $0 + $1.text.count }
        let showCaret = caretVisible(chars: total, elapsed: elapsed, cps: cps, enabled: caret != nil)
        var out = AttributedString()
        if elapsed.isInfinite || (RevealTiming.isSettled(chars: total, elapsed: elapsed, charsPerSecond: cps) && !showCaret) {
            for s in segs { out += piece(s.text, s.color, s.weight) }
            return out
        }
        let rv = RevealTiming.revealedCount(chars: total, elapsed: elapsed, charsPerSecond: cps)
        let st = RevealTiming.settledCount(chars: total, elapsed: elapsed, charsPerSecond: cps)
        let tick = Int(max(0, elapsed) / 0.055)
        var placed = !showCaret, g = 0
        for s in segs {
            let chars = Array(s.text), n = chars.count
            let a = min(n, max(0, st - g)), b = min(n, max(0, rv - g))
            if a > 0 { out += piece(String(chars[0..<a]), s.color, s.weight) }
            if b > a { out += piece(GlyphScramble.scrambled(chars[a..<b], startIndex: g + a, tick: tick), s.color, s.weight) }
            if !placed, rv - g <= n { out += piece("█", caret ?? s.color, .regular); placed = true }
            if b < n { out += piece(String(chars[b...]), .clear, s.weight) }
            g += n
        }
        return out
    }

    /// 커서: 타이핑 중엔 글자 앞쪽에 계속, 끝난 뒤 1.1초는 깜빡이고 사라진다
    static func caretVisible(chars: Int, elapsed: Double, cps: Double, enabled: Bool) -> Bool {
        guard enabled, elapsed.isFinite, elapsed >= 0 else { return false }
        let after = elapsed - Double(chars) / cps
        if after < 0 { return true }
        return after < RevealTiming.pillCaretLinger && Int(after / (RevealTiming.pillCaretPeriod / 2)) % 2 == 0
    }
}

/// 왼쪽에서 오른쪽으로 `elapsed` 만큼 드러나는 마스크(글자가 아닌 칸 막대 등). 연출이 끝나면(무한대) 마스크 자체를 빼서 비용이 0 이다.
struct RevealMask: ViewModifier {
    let elapsed: Double
    var xStart: CGFloat = 0
    func body(content: Content) -> some View {
        if elapsed.isInfinite {
            content
        } else {
            let px = CGFloat(max(0, elapsed) * RevealTiming.cardCharsPerSecond) * CGFloat(RevealTiming.cellWidth)
            let x = max(0, (px / CGFloat(RevealTiming.cellWidth)).rounded(.down) * CGFloat(RevealTiming.cellWidth) - xStart)
            content.mask(alignment: .leading) { Rectangle().frame(width: x) }
        }
    }
}

/// 켜진 칸 / 꺼진 칸 막대(tmux 식). 칸 6.2 × 9pt, 칸 사이 1pt.
struct CellBar: View {
    let on: Int
    let total: Int
    static let cellW: CGFloat = 6.2
    static let cellH: CGFloat = 9
    var width: CGFloat { CGFloat(total) * Self.cellW + CGFloat(max(0, total - 1)) }

    var body: some View {
        Canvas { ctx, _ in
            for i in 0..<total {
                let r = CGRect(x: CGFloat(i) * (Self.cellW + 1), y: 0, width: Self.cellW, height: Self.cellH)
                ctx.fill(Path(r), with: .color(i < on ? TermStyle.acc : TermStyle.dim))
            }
        }
        .frame(width: width, height: Self.cellH)
        .accessibilityHidden(true)
    }
}

/// CPU 1분 점 그래프(btop 식, 60열 × 16행). 오른쪽 끝이 가장 최근. 기록이 짧으면 왼쪽은 꺼진 점, 측정 못 한 구간(nil)도 꺼진 점으로 둔다(가짜 연속선 금지).
struct DotGraph: View {
    let values: [Double?]
    static let cols = 60, rows = 16
    static let width: CGFloat = 360, height: CGFloat = 76

    var body: some View {
        let data = Array(values.suffix(Self.cols))
        Canvas { ctx, size in
            let px = size.width / CGFloat(Self.cols), py = size.height / CGFloat(Self.rows)
            let off = Self.cols - data.count
            // 점 960개를 하나씩 그리면 1초마다 비용이 크다 → 같은 모양을 한 경로로 묶는다(꺼진 점 1·맨 윗점 1·몸통 알파 4단계)
            var dimPath = Path(), topPath = Path()
            var body = [Path](repeating: Path(), count: 4)
            for c in 0..<Self.cols {
                let v: Double? = c < off ? nil : data[c - off]
                let lit = v.map { max(1, Int(($0 / 100 * Double(Self.rows)).rounded())) } ?? 0
                let x = (CGFloat(c) + 0.5) * px
                for r in 0..<Self.rows {
                    let y = size.height - (CGFloat(r) + 0.5) * py
                    if r < lit {
                        let rad: CGFloat = 1.25
                        let rect = CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2)
                        if r == lit - 1 { topPath.addEllipse(in: rect) }
                        else {
                            let frac = Double(r) / Double(max(1, lit))         // 0..<1: 위로 갈수록 진하게(시안 .55 → 1)
                            body[min(3, Int(frac * 4))].addEllipse(in: rect)
                        }
                    } else {
                        dimPath.addEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6))
                    }
                }
            }
            ctx.fill(dimPath, with: .color(TermStyle.dim.opacity(0.55)))
            for (k, p) in body.enumerated() { ctx.fill(p, with: .color(TermStyle.fg3.opacity(0.55 + 0.45 * (Double(k) + 0.5) / 4))) }
            ctx.fill(topPath, with: .color(TermStyle.acc))
        }
        .frame(width: Self.width, height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU 최근 1분 추이")
    }
}

/// 10칸 점선 진행 링: 한 칸 = 10%. 켜진 칸은 위에서부터 시계 방향.
struct DashRing: View {
    let percent: Int
    /// 켜지는 칸 수(0...10)
    static func litCount(percent: Int) -> Int { min(10, max(0, Int((Double(percent) / 10).rounded()))) }

    var body: some View {
        let lit = Self.litCount(percent: percent)
        Canvas { ctx, size in
            let s = size.width / 16
            for i in 0..<10 {
                var p = Path()
                for k in 0...6 {
                    let deg = Double(i * 36 + 4) + Double(k) * (28.0 / 6) - 90
                    let a = deg * .pi / 180
                    let pt = CGPoint(x: (8 + 6.6 * cos(a)) * s, y: (8 + 6.6 * sin(a)) * s)
                    if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                ctx.stroke(p, with: .color(i < lit ? TermStyle.acc : TermStyle.dim), style: StrokeStyle(lineWidth: 2.3 * s, lineCap: .butt, lineJoin: .round))
            }
        }
    }
}

/// 한 번 재생하는 연출 시계: `id` 가 바뀌면 `duration` 초 동안만 30fps 로 돌고 멈춘다(평소엔 시계가 없다). `enabled` 가 꺼져 있으면 연출 없이 그대로.
struct PlayOnChange<ID: Hashable, Content: View>: View {
    let id: ID
    let duration: Double
    let enabled: Bool
    var fps: Double = 30
    @ViewBuilder let content: (_ elapsed: Double) -> Content
    @State private var start = Date.distantPast
    @State private var active = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / fps, paused: !active)) { tl in
            content(active && enabled ? tl.date.timeIntervalSince(start) : .infinity)
        }
        .task(id: id) {
            guard enabled else { return }
            start = Date(); active = true
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            active = false
        }
    }
}

/// 펼친 뒤 처음 몇 번만 깜빡이고 멈추는 블록 커서(시안: 4번). 움직임 줄이기면 고정. 멈춘 뒤엔 시계(TimelineView)를 아예 내려 비용이 0 이다.
struct BlinkCaret: View {
    let start: Date
    let reduceMotion: Bool
    @State private var done = false

    var body: some View {
        Group {
            if reduceMotion || done {
                Rectangle().fill(TermStyle.acc).frame(width: 7, height: 15)
            } else {
                TimelineView(.periodic(from: start, by: RevealTiming.pillCaretPeriod / 2)) { tl in
                    let phase = Int(max(0, tl.date.timeIntervalSince(start)) / (RevealTiming.pillCaretPeriod / 2))
                    Rectangle().fill(TermStyle.acc).frame(width: 7, height: 15).opacity(phase % 2 == 0 ? 1 : 0)
                }
            }
        }
        .task(id: start) {
            done = reduceMotion
            guard !reduceMotion else { return }
            try? await Task.sleep(nanoseconds: UInt64(RevealTiming.pillCaretPeriod * 4 * 1_000_000_000))
            done = true
        }
        .accessibilityHidden(true)
    }
}

/// 시안 `v2jit`: 글자를 가로로 잘라 흔든다(0.2초). 덧칠 층 없이 글자 자체를 자르는 방식 — 단계마다 (좌우 이동, 보이는 세로 구간).
struct GlitchSlice: ViewModifier {
    let step: Int?
    private static let frames: [(dx: CGFloat, top: CGFloat, bottom: CGFloat)] = [
        (-4, 0, 0.45), (3, 0.40, 1), (-2, 0.15, 0.70), (2, 0, 0.80), (-1, 0, 1),
    ]
    func body(content: Content) -> some View {
        if let step, step < Self.frames.count {
            let f = Self.frames[step]
            content
                .mask { GeometryReader { g in
                    Rectangle().frame(width: g.size.width + 24, height: g.size.height * (f.bottom - f.top))
                        .offset(x: -12, y: g.size.height * f.top)
                } }
                .offset(x: f.dx)
        } else {
            content
        }
    }
}

struct ChevronShape: Shape {
    let pointsRight: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        if pointsRight { p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: r.width, y: r.height / 2)); p.addLine(to: CGPoint(x: 0, y: r.height)) }
        else { p.move(to: CGPoint(x: r.width, y: 0)); p.addLine(to: CGPoint(x: 0, y: r.height / 2)); p.addLine(to: CGPoint(x: r.width, y: r.height)) }
        p.closeSubpath()
        return p
    }
}
