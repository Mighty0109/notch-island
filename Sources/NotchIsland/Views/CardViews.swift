import SwiftUI
import NotchIslandCore

struct CardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension IslandModel {
    var batteryText: String {
        switch snapshot.battery.status {
        case .ok:
            guard let b = snapshot.battery.value else { return "bat 확인 중" }
            return "bat \(b.percent)% " + (b.isCharging ? "충전 중" : (b.onACPower ? "전원" : "방전"))
        case .unsupported: return "bat 없음"
        default: return "bat 확인 중"
        }
    }
    /// `mem 93.0/128G ◇` — 활성 상태 보기 "사용된 메모리"(앱+와이어드+압축) / 물리 메모리 + 압박 모양
    var memoryUsedText: String {
        guard let u = snapshot.memoryUsage.value else { return "mem 확인 중" }
        return String(format: "mem %.1f/%.0fG", Double(u.usedBytes) / MemoryMath.bytesPerGB, Double(u.totalBytes) / MemoryMath.bytesPerGB) + " " + display(.memory).glyph
    }
    var diskText: String {
        guard let d = snapshot.disk.value else { return "disk 확인 중" }
        return String(format: "disk %.0fG 남음", d.freeGB)
    }
    var netText: String {
        guard let n = snapshot.network.value else { return "↓— ↑—" }
        return "↓\(compactRate(n.downBytesPerSec)) ↑\(compactRate(n.upBytesPerSec))"
    }
    var clockText: String { IslandModel.clockFormatter.string(from: snapshot.updatedAt) }
    static let clockFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
}

/// 상태줄용 짧은 속도 표기 — `0.4K` · `1.2M` (시안)
func compactRate(_ bytesPerSec: Double) -> String {
    // 상태줄 폭(684pt)에 들어가게 두 자리 이상이면 소수점을 뗀다: 0.4K · 12K · 354K · 1.2M
    let (v, unit) = bytesPerSec >= 1_000_000 ? (bytesPerSec / 1_000_000, "M") : (bytesPerSec / 1000, "K")
    return String(format: v >= 10 ? "%.0f%@" : "%.1f%@", v, unit)
}

/// 카드 줄 순번(`RevealTiming.lineStart` 의 입력) — 시안의 DOM 순서: 프롬프트 · 작업 · cpu · top5(머리+5) · cores(머리+18) · llm(머리+6) · 로그 3 · 상태줄
private enum Row {
    static let prompt = 0, job = 1, cpuHead = 2, procHead = 3, proc0 = 4, coreHead = 9, core0 = 10, llmHead = 28, llm0 = 29, log0 = 35, footer = 38
}

/// 펼침 카드. 접힘 줄(3칸)은 카드 위 제자리에 그대로 있고, 카드는 그 아래로만 펼쳐진다.
/// 펼친 직후 약 0.95초만 시계(30fps)가 돈다: 창틀 → 줄 타이핑 + 가타카나 해독, 바탕에 코드 비. 끝나면 시계가 멈추고 정적이다.
struct CardView: View {
    @ObservedObject var model: IslandModel
    @State private var running = true

    var body: some View {
        let animate = !model.reduceMotion && running
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animate)) { tl in
            CardFrame(model: model, t: animate ? max(0, tl.date.timeIntervalSince(model.openedAt)) : .infinity)
        }
        .task(id: model.openedAt) {
            running = true
            guard !model.reduceMotion else { running = false; return }
            try? await Task.sleep(nanoseconds: UInt64(RevealTiming.cardTotal * 1_000_000_000))
            running = false
        }
    }
}

/// 카드 한 프레임(시각 `t`): 본문 + 글자 **아래** 바탕층의 코드 비. 캡처·테스트도 이 뷰를 그대로 그린다.
struct CardFrame: View {
    @ObservedObject var model: IslandModel
    let t: Double

    var body: some View {
        CardBody(model: model, t: t)
            .background {
                // 코드 비는 글자 아래 바탕층(글자 위 덧칠 금지). 카드 크기로 고정된 캔버스 — 펼치는 동안 섬과 같이 커지며 번지지 않는다.
                if t.isFinite, t < CodeRainPainter.duration {
                    Canvas { ctx, size in CodeRainPainter.draw(&ctx, size: size, t: t, color: ThemeStyle.matrix.accent) }
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}

/// 카드 본문. `t` = 펼친 뒤 지난 초(무한대 = 연출 끝/없음). 모든 섹션이 처음부터 자리를 잡아 높이가 변하지 않는다(426pt 고정).
struct CardBody: View {
    @ObservedObject var model: IslandModel
    let t: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PromptRow(model: model, t: t).frame(height: 32)
            JobLine(model: model, e: lineElapsed(t, Row.job)).padding(.top, 8)
            PaneGrid(model: model, t: t).padding(.top, 6)
            PowerlineFooter(model: model, e: lineElapsed(t, Row.footer)).padding(.top, 8)
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(width: IslandLayout.cardWidth, alignment: .topLeading)
        .background(GeometryReader { g in Color.clear.preference(key: CardHeightKey.self, value: g.size.height) })
    }
}

private func lineElapsed(_ t: Double, _ order: Int) -> Double { t.isInfinite ? .infinity : t - RevealTiming.lineStart(order: order) }

// MARK: - 프롬프트 줄 (상태 문장 + 고정 표시 + 닫기)

struct PromptRow: View {
    @ObservedObject var model: IslandModel
    let t: Double

    var body: some View {
        let h = model.headline
        HStack(spacing: 10) {
            PlayOnChange(id: h.text, duration: 0.5, enabled: t.isInfinite && !model.reduceMotion) { play in
                let e = t.isInfinite ? play : lineElapsed(t, Row.prompt)
                HStack(spacing: 8) {
                    TypedLine(segs: [TermSeg("❯", TermStyle.acc, .heavy), TermSeg(" " + ThemeStyle.glyph(raw: h.level) + " ", TermStyle.level(h.level), .bold),
                                     TermSeg(h.text, TermStyle.fg, .bold)], size: 13, elapsed: e)
                    BlinkCaret(start: model.openedAt, reduceMotion: model.reduceMotion)
                        .opacity(RevealTiming.isTyped(chars: h.text.count + 4, elapsed: e) ? 1 : 0)
                }
            }
            Spacer(minLength: 4)
            if model.phase == .pinned {
                HStack(spacing: 4) {
                    Image(systemName: "pin.fill").font(.system(size: 10))
                    Text("고정됨").font(TermStyle.font(12, .semibold))
                }
                .foregroundColor(TermStyle.fg2)
            }
            Button { model.close() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundColor(TermStyle.fg)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(TermStyle.fg3, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("닫기")
        }
        .frame(height: 32)
    }
}

// MARK: - 작업 줄 ([charge] ▮▮▮▮ 62% · 배터리 충전 / [idle])

struct JobLine: View {
    @ObservedObject var model: IslandModel
    let e: Double
    private static let cellW = RevealTiming.cellWidth

    var body: some View {
        HStack(spacing: 10) {
            if let job = model.job {
                let barX = 8 * Self.cellW + 10
                let bar = CellBar(on: Int((Double(job.percent) / 100 * 36).rounded()), total: 36)
                TypedLine(segs: [TermSeg("[charge]", TermStyle.kw)], elapsed: e)
                bar.modifier(RevealMask(elapsed: e, xStart: CGFloat(barX)))
                let after = e - (barX + Double(bar.width) + 10) / (RevealTiming.cardCharsPerSecond * Self.cellW)
                TypedLine(segs: [TermSeg(String(format: "%3d%%", job.percent), TermStyle.acc, .bold)], elapsed: after)
                TypedLine(segs: [TermSeg("· " + job.label, TermStyle.fg2)], elapsed: after - 0.015)
            } else {
                TypedLine(segs: [TermSeg("[idle]  ", TermStyle.kw), TermSeg("진행 중인 작업 없음", TermStyle.fg2)], elapsed: e)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 24)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 창 분할 (cpu · top5 · cores · llm/ports · 로그)

struct PaneGrid: View {
    @ObservedObject var model: IslandModel
    let t: Double
    private static let w: CGFloat = 684, rightX: CGFloat = 404 + 12, rightW: CGFloat = 684 - 404 - 12

    var body: some View {
        let u = RevealTiming.ruleProgress(elapsed: t)
        ZStack(alignment: .topLeading) {
            cpuPane.frame(width: 392, height: 116, alignment: .topLeading)
            procPane.frame(width: Self.rightW, height: 116, alignment: .topLeading).offset(x: Self.rightX)
            corePane.frame(width: 392, height: 126, alignment: .topLeading).offset(y: 116)
            llmPane.frame(width: Self.rightW, height: 126, alignment: .topLeading).offset(x: Self.rightX, y: 116)
            logPane.frame(width: Self.w, height: 62, alignment: .topLeading).offset(y: 242)
            // 창틀: 0.2초에 그어진다
            ForEach([0, 116, 242], id: \.self) { y in
                Rectangle().fill(TermStyle.rule).frame(width: Self.w * u, height: 1).offset(y: CGFloat(y))
            }
            Rectangle().fill(TermStyle.rule).frame(width: 1, height: 242 * u).offset(x: 404)
        }
        .frame(width: Self.w, height: 304, alignment: .topLeading)
    }

    private func e(_ order: Int) -> Double { lineElapsed(t, order) }

    private func head(_ name: String, dim: String = "", order: Int, right: String? = nil) -> some View {
        HStack(spacing: 8) {
            TypedLine(segs: [TermSeg(name, TermStyle.fg3, .semibold)] + (dim.isEmpty ? [] : [TermSeg("  " + dim, TermStyle.fg3)]), elapsed: e(order))
            Spacer(minLength: 0)
            if let right { TypedLine(segs: [TermSeg(right, TermStyle.acc, .bold)], elapsed: e(order)) }
        }
        .frame(height: 18)
    }

    // cpu · 최근 1분
    private var cpuPane: some View {
        let cpu = model.snapshot.cpu.value
        return VStack(alignment: .leading, spacing: 0) {
            head("cpu · 최근 1분", order: Row.cpuHead, right: cpu.map { String(format: "%.0f%%", $0) } ?? "—")
                .frame(width: 392 - 12)
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("100"); Spacer(minLength: 0); Text("50"); Spacer(minLength: 0); Text("0")
                }
                .font(TermStyle.font(12)).foregroundColor(TermStyle.fg3).frame(width: 24, height: 76)
                DotGraph(values: model.history.cpu.values)
            }
            .padding(.top, 4)
        }
        .padding(.top, 6)
    }

    // top 5
    private var procPane: some View {
        let list = Array((model.snapshot.topProcesses.value ?? []).prefix(5))
        func lpad(_ s: String, _ n: Int) -> String { String(repeating: " ", count: max(0, n - s.count)) + s }
        func rpad(_ s: String, _ n: Int) -> String { s + String(repeating: " ", count: max(0, n - s.count)) }
        func mem(_ b: UInt64) -> String {
            let g = Double(b) / 1_073_741_824
            return g >= 1 ? String(format: "%.1fG", g) : String(format: "%.0fM", Double(b) / 1_048_576)
        }
        return VStack(alignment: .leading, spacing: 0) {
            head("top 5", dim: "cpu% · 코어 1개 = 100%", order: Row.procHead)
            ForEach(0..<5, id: \.self) { i in
                Group {
                    if i < list.count {
                        let p = list[i]
                        TypedLine(segs: [TermSeg(lpad("×\(p.count)", 3) + "  ", TermStyle.fg3), TermSeg(rpad(String(p.name.prefix(16)), 16) + " ", TermStyle.fg),
                                         TermSeg(lpad(String(format: "%.0f", p.cpuPercent), 5), TermStyle.acc), TermSeg(" " + lpad(mem(p.residentBytes), 6), TermStyle.fg)],
                                  elapsed: e(Row.proc0 + i))
                    } else {
                        TypedLine(segs: [TermSeg(i == 0 ? "…" : "", TermStyle.fg3)], elapsed: e(Row.proc0 + i))
                    }
                }
                .frame(height: 16, alignment: .leading)
            }
        }
        .padding(.top, 6)
    }

    // cores 18 — 3열 × 6행(세로로 채움). 번호만 표시(코어 번호↔종류 매핑은 공개 문서가 없다 — decisions D6)
    // 칸 막대 18개를 캔버스 하나에 그린다(막대마다 뷰를 두면 1초마다 18개를 다시 그려 펼침 고정 idle 이 올랐다 — 프로파일 3.3ms/s).
    // 글자는 줄마다 한 덩어리(이름 · 막대 자리 공백 · 퍼센트).
    private static let cell = RevealTiming.cellWidth, colChars = 14, colPitch = 14 * RevealTiming.cellWidth + 18

    private var corePane: some View {
        let cores = model.lastCores
        let n = max(cores.count, ProcessInfo.processInfo.processorCount)
        let topo = model.topology.groups.map { "\($0.name) \($0.count)" }.joined(separator: " + ")
        let t = self.t
        return VStack(alignment: .leading, spacing: 0) {
            head("cores \(n)", dim: topo, order: Row.coreHead)
            HStack(alignment: .top, spacing: 18) {
                ForEach(0..<3, id: \.self) { col in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<6, id: \.self) { row in
                            coreText(col * 6 + row, cores).frame(width: CGFloat(Self.colChars) * CGFloat(Self.cell), height: 16, alignment: .leading)
                        }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for i in 0..<18 {
                        let col = i / 6, row = i % 6
                        let el = lineElapsed(t, Row.core0 + i)
                        let px = el.isInfinite ? Double.infinity : max(0, el) * RevealTiming.cardCharsPerSecond * Self.cell
                        let v = i < cores.count ? cores[i] : 0, on = i < cores.count ? Int((v * 6).rounded()) : 0
                        let x0 = CGFloat(col) * CGFloat(Self.colPitch) + CGFloat(4 * Self.cell), y0 = CGFloat(row) * 16 + 3.5
                        for k in 0..<6 {
                            if px.isFinite, px < 4 * Self.cell + Double(k + 1) * 7.2 { break }       // 타이핑이 거기까지 안 왔다
                            ctx.fill(Path(CGRect(x: x0 + CGFloat(k) * (CellBar.cellW + 1), y: y0, width: CellBar.cellW, height: CellBar.cellH)),
                                     with: .color(k < on ? TermStyle.acc : TermStyle.dim))
                        }
                    }
                }
                .allowsHitTesting(false).accessibilityHidden(true)
            }
            .padding(.top, 2)
        }
        .padding(.top, 6)
    }

    private func coreText(_ i: Int, _ cores: [Double]) -> some View {
        let el = e(Row.core0 + i)
        let label = "c\(i)"
        let ready = i < cores.count
        let name = label + String(repeating: " ", count: 4 - label.count)
        let gap = String(repeating: " ", count: 6)                    // 막대 자리(6칸 ≈ 막대 6.2×6+5)
        return TypedLine(segs: [TermSeg(name, TermStyle.fg3), TermSeg(gap, TermStyle.fg3),
                                TermSeg(ready ? String(format: "%3.0f%%", cores[i] * 100) : " …", ready ? TermStyle.fg : TermStyle.fg3)], elapsed: el)
    }

    // llm · ports — 실데이터는 v0.2(센서·포트). 가짜 값은 안 쓰고 자리만 정직하게 표시한다.
    private var llmPane: some View {
        let lines: [[TermSeg]] = [
            [TermSeg("llm   ", TermStyle.fg3), TermSeg(model.settings.localModelEnabled ? "켜짐 (v0.2 표시)" : "꺼짐", TermStyle.fg2)],
            [TermSeg("gpu   ", TermStyle.fg3), TermSeg("n/a (v0.2 센서 모듈)", TermStyle.fg2)],
            [TermSeg("power ", TermStyle.fg3), TermSeg("n/a (v0.2 센서 모듈)", TermStyle.fg2)],
            [TermSeg("ports ", TermStyle.fg3), TermSeg("(v0.2 자리)", TermStyle.fg2)],
        ]
        return VStack(alignment: .leading, spacing: 0) {
            head("llm · ports", order: Row.llmHead)
            ForEach(0..<6, id: \.self) { i in
                TypedLine(segs: i < lines.count ? lines[i] : [TermSeg("", TermStyle.fg2)], elapsed: e(Row.llm0 + i))
                    .frame(height: 16, alignment: .leading)
            }
        }
        .padding(.top, 6)
    }

    // 로그 스트림: 최근 3줄. 새 줄은 아래에서 타이핑 + 해독으로 들어오고 위 줄이 밀려 올라간다.
    private var logPane: some View {
        let lines = model.statusLog.lines
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<StatusLog.capacity, id: \.self) { i in
                let line: LogLine? = i < lines.count ? lines[i] : nil
                let newest = i == StatusLog.capacity - 1
                PlayOnChange(id: newest ? (line?.id ?? -1) : -2, duration: 0.27, enabled: newest && t.isInfinite && !model.reduceMotion, fps: 15) { play in
                    let el = t.isInfinite ? play : e(Row.log0 + i)
                    TypedLine(segs: segs(line), elapsed: el)
                }
                .frame(height: 16, alignment: .leading)
            }
        }
        .padding(.top, 7)
    }

    private func segs(_ l: LogLine?) -> [TermSeg] {
        guard let l else { return [TermSeg("", TermStyle.fg2)] }
        let lvl = l.level == .warn ? "warn" : "info"
        return [TermSeg(l.time + "  ", TermStyle.fg3), TermSeg(lvl + "  ", l.level == .warn ? TermStyle.warn : TermStyle.kw), TermSeg(l.text, TermStyle.fg2)]
    }
}

// MARK: - Powerline 상태줄 (시각 ▸ 메모리 ▸ 디스크·네트·배터리 ◂ 활성 상태 보기)

struct PowerlineFooter: View {
    @ObservedObject var model: IslandModel
    let e: Double

    var body: some View {
        // 각 칸의 시작 위치(pt)를 글자 수로 어림해 줄 전체 타이핑 속도에 맞춘다
        let cell = RevealTiming.cellWidth
        let after = { (x: Double) -> Double in e - x / (RevealTiming.cardCharsPerSecond * cell) }
        let clk = model.clockText, mem = model.memoryUsedText, disk = model.diskText, net = model.netText, bat = model.batteryText
        let xMem = Double(clk.count) * cell + 18 + 8
        let xDisk = xMem + Double(mem.count) * cell + 18 + 8
        let xNet = xDisk + Double(disk.count) * cell + 18
        let xBat = xNet + Double(net.count) * cell + 18
        HStack(spacing: 0) {
            seg(clk, TermStyle.fg, TermStyle.segA, after(0))
            ChevronShape(pointsRight: true).fill(TermStyle.segA).frame(width: 8, height: 24).background(TermStyle.segB)
            seg(mem, TermStyle.fg, TermStyle.segB, after(xMem))
            ChevronShape(pointsRight: true).fill(TermStyle.segB).frame(width: 8, height: 24).background(TermStyle.segC)
            seg(disk, TermStyle.fg2, TermStyle.segC, after(xDisk))
            seg(net, TermStyle.fg2, TermStyle.segC, after(xNet))
            seg(bat, TermStyle.fg2, TermStyle.segC, after(xBat))
            Spacer(minLength: 0)
            ChevronShape(pointsRight: false).fill(TermStyle.segC).frame(width: 8, height: 24)
            Button { ActionService.openActivityMonitor() } label: {
                TypedLine(segs: [TermSeg("활성 상태 보기 열기", TermStyle.fg, .semibold)], elapsed: e - 0.19)
                    .padding(.horizontal, 12).frame(height: 24).background(TermStyle.segA)
            }
            .buttonStyle(.plain)
            .accessibilityHint("활성 상태 보기 앱을 엽니다")
        }
        .frame(width: 684, height: 24)
        .modifier(RevealMask(elapsed: e, xStart: 0))
    }

    private func seg(_ text: String, _ fg: Color, _ bg: Color, _ el: Double) -> some View {
        TypedLine(segs: [TermSeg(text, fg)], elapsed: el).padding(.horizontal, 8).frame(height: 24).background(bg)
    }
}
