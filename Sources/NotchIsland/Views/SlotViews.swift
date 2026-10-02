import SwiftUI
import NotchIslandCore

/// 접힘 줄 요소의 글리프·글자 크기(pt). 아이콘·값은 13pt 이상(선명하게). 간격은 `HeadSpacing`(Core) 토큰이 정한다.
/// 펼침에서 아이콘 뒤에 붙는 항목 이름(터미널 톤 소문자). 접힘에는 없다.
enum HeadLabel {
    static let cpu = "cpu", mem = "mem", thermal = "temp"
}

enum HeadMetrics {
    static let icon: CGFloat = 13
    static let text: CGFloat = 13
    static let word: CGFloat = 12
    // 아이콘은 실제 글리프 폭에 맞춘다(온도계는 좁다) — 빈 여백이 간격처럼 보이지 않게
    static let cpuIcon: CGFloat = 14
    static let memIcon: CGFloat = 15
    static let thermIcon: CGFloat = 10
    static let glyph: CGFloat = 10          // ◇ ◈ ◆ ◉ (13pt)
    static let cpuValue: CGFloat = 32       // "100%" (13pt 고정폭 4글자)
    static let memValue: CGFloat = 24       // "99%" — 100% 는 사실상 없다
    static let ring: CGFloat = 16
}

/// 접힘 줄의 칸: 시스템 아이콘(SF Symbols) + 값(+단계 모양)만. 단어는 화면에 없고 호버 툴팁·VoiceOver 라벨,
/// 그리고 펼쳤을 때 붙는 `WordLabel` 에만 있다. 색만으로 구분하지 않도록 단계마다 모양이 다르다(◇ ◈ ◆ ◉).
struct SlotView: View {
    @ObservedObject var model: IslandModel
    let kind: SlotKind

    private var symbol: String {
        switch kind {
        case .cpu: return "cpu"
        case .memory: return "memorychip.fill"
        case .thermal: return "thermometer.medium"
        }
    }

    private var itemLabel: String {
        switch kind {
        case .cpu: return HeadLabel.cpu
        case .memory: return HeadLabel.mem
        case .thermal: return HeadLabel.thermal
        }
    }

    private var iconWidth: CGFloat {
        switch kind {
        case .cpu: return HeadMetrics.cpuIcon
        case .memory: return HeadMetrics.memIcon
        case .thermal: return HeadMetrics.thermIcon
        }
    }

    var body: some View {
        let st = ThemeStyle.matrix
        let d = model.display(kind)
        let color = st.color(forLevel: d.level)
        let sp = HeadSpacing.at(open: model.phase.isOpen)        // 접힘 4/3 · 펼침 5/4 — 펼침 애니메이션과 함께 부드럽게 바뀐다
        HStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: HeadMetrics.icon, weight: .semibold))
                .foregroundColor(st.on2)
                .frame(width: iconWidth)
            WordSlot(model: model, text: itemLabel, lead: sp.iconValue, color: st.on3)         // 펼칠 때만: 아이콘 ▸ 이름 ▸ 값
            switch kind {
            case .cpu:
                ScrambleText(text: d.value, font: st.font(HeadMetrics.text, .bold), color: st.on, reduceMotion: model.reduceMotion)
                    .frame(width: HeadMetrics.cpuValue, alignment: .leading).padding(.leading, sp.iconValue)
            case .memory:
                ScrambleText(text: d.pct, font: st.font(HeadMetrics.text, .bold), color: st.on, reduceMotion: model.reduceMotion)
                    .frame(width: HeadMetrics.memValue, alignment: .leading).padding(.leading, sp.iconValue)
                glyph(d, st, color).padding(.leading, sp.valueGlyph)
            case .thermal:
                glyph(d, st, color).padding(.leading, sp.iconValue)
            }
        }
        .help(d.spoken)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(d.spoken)
    }

    private func glyph(_ d: SlotDisplay, _ st: ThemeStyle, _ color: Color) -> some View {
        Text(d.glyph).font(st.font(HeadMetrics.text, .bold)).foregroundColor(d.checking ? st.on3 : color)
            .frame(width: HeadMetrics.glyph)
    }
}

/// 진행 작업 자리(라이브 액티비티형): 라벨 없이 작은 10칸 점선 링만(한 칸 = 10%). 퍼센트는 툴팁과 펼침 라벨·카드에 있다. v0.1 은 충전 중 1종만 실데이터.
/// 안 4 시안대로 정적이다 — 예전의 0.5초 계단 궤도 점(상시 TimelineView)은 뺐다.
struct JobPod: View {
    @ObservedObject var model: IslandModel
    let job: JobInfo

    var body: some View {
        DashRing(percent: job.percent)
        .frame(width: HeadMetrics.ring, height: HeadMetrics.ring)
        .help("\(job.short) \(job.percent)%")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(job.label)
        .accessibilityValue("\(job.percent) 퍼센트")
    }
}

/// 펼쳤을 때만 칸 뒤(바깥쪽)에 붙는 단어. 폭이 0 → 단어 폭으로 펼침 애니메이션과 함께 벌어지고 글자는 페이드인한다.
/// 접힘에선 폭 0 이라 자리를 차지하지 않는다(촘촘).
struct WordSlot: View {
    @ObservedObject var model: IslandModel
    let text: String
    var lead: CGFloat = HeadSpacing.collapsed.glyphWord        // 모양↔단어 · 링↔라벨 (5pt)
    var color: Color = ThemeStyle.matrix.on2
    var body: some View {
        let open = model.phase.isOpen && !text.isEmpty
        Text(text)
            .font(ThemeStyle.matrix.font(HeadMetrics.word, .semibold)).foregroundColor(color)
            .lineLimit(1).fixedSize()
            .padding(.leading, lead)
            .opacity(open ? 1 : 0)
            .animation(model.reduceMotion ? nil : (open ? .easeOut(duration: 0.2).delay(0.12) : .easeIn(duration: 0.08)), value: open)
            .frame(width: open ? model.measureWord(text) + lead : 0, alignment: .leading)
            .clipped()
            .accessibilityHidden(true)      // 같은 말이 각 칸의 접근성 라벨에 이미 있다
    }
}
