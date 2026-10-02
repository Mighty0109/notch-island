import SwiftUI
import NotchIslandCore

/// 패널 안의 모든 그림. 섬(접힘 ↔ 펼침 스프링), 물방울, 알약 글자를 한 좌표계에서 그린다.
struct IslandRootView: View {
    @ObservedObject var model: IslandModel
    @State private var cardVisible = false      // 마운트 직후 0 → 1 로 페이드인하기 위한 한 틱 지연

    var body: some View {
        let layout = model.layout
        let isOpen = model.phase.isOpen
        let nh = layout.notchHeight

        ZStack(alignment: .topLeading) {
            if model.drop != .hidden, !isOpen {
                DropLayer(model: model, layout: layout)
            }

            // 섬 외곽: 접힘 ↔ 펼침 끝값을 하나의 진행도로 단조 보간(왼쪽·오른쪽·아래 끝이 접힘 끝 안쪽으로 못 들어옴), 머리줄·카드는 그 끝에서 위치를 정한다
            IslandSurface(data: IslandAnim(shape: layout.shape, progress: isOpen ? 1 : 0),
                          card: { _ in
                              if model.cardMounted {
                                  // 카드는 카메라(패널 가운데) 중심 720pt 고정 폭. 닫을 땐 섬이 줄기 전에 먼저 페이드 아웃(0.12초)한다.
                                  CardView(model: model)
                                      .frame(width: IslandLayout.cardWidth, alignment: .top)
                                      .contentShape(Rectangle())
                                      .onTapGesture { model.click(.card) }
                                      .opacity(cardVisible ? 1 : 0)
                                      .animation(model.reduceMotion ? nil : (cardVisible ? .easeOut(duration: 0.12) : .easeIn(duration: 0.12)), value: cardVisible)
                                      .allowsHitTesting(isOpen)
                                      .accessibilityHidden(!isOpen)
                              }
                          },
                          head: { e in
                              HeadStrip(model: model, wingLeft: CGFloat(e.headLeft) - layout.notchWidth / 2,
                                        wingRight: CGFloat(e.headRight) - layout.notchWidth / 2, notchWidth: layout.notchWidth)
                          },
                          notchHeight: nh)
            .frame(width: IslandLayout.panelWidth, alignment: .top)       // 카메라(패널 가운데) 기준 배치

            PillText(model: model, layout: layout)
        }
        .frame(width: IslandLayout.panelWidth, height: IslandLayout.panelHeight(notchHeight: nh), alignment: .topLeading)
        .opacity(model.phase == .hidden ? 0 : 1)
        .environment(\.islandReduceMotion, model.reduceMotion)
        .onChange(of: isOpen) { _, open in cardVisible = open }
        .onPreferenceChange(CardHeightKey.self) { h in model.updateCardHeight(h) }
    }
}

/// 애니메이션 벡터: [진행도, 섬 모양 끝값 8개]. 진행도(0 접힘 ↔ 1 펼침)만 스프링으로 움직이고 나머지는 보통 상수 — 카드 높이·날개 폭이 펼침 중에 바뀌어도 같은 곡선으로 따라간다.
struct IslandAnim: VectorArithmetic {
    var v: [Double]
    init(v: [Double]) { self.v = v }
    init(shape: IslandShape, progress: Double) { v = [progress] + shape.packed }
    var progress: Double { v[0] }
    var shape: IslandShape { IslandShape(packed: Array(v[1...])) }
    static var zero: IslandAnim { IslandAnim(v: [Double](repeating: 0, count: 9)) }
    static func + (a: IslandAnim, b: IslandAnim) -> IslandAnim { IslandAnim(v: zip(a.v, b.v).map(+)) }
    static func - (a: IslandAnim, b: IslandAnim) -> IslandAnim { IslandAnim(v: zip(a.v, b.v).map(-)) }
    mutating func scale(by rhs: Double) { v = v.map { $0 * rhs } }
    var magnitudeSquared: Double { v.reduce(0) { $0 + $1 * $1 } }
}

/// 섬 본체: 검은 바탕 + 카드 + 머리줄을 한 좌표계에 둔다. 외곽(왼쪽·오른쪽·아래 끝)은 `IslandGeometry` 가 진행도 하나로 정하고,
/// 머리줄은 카메라에 붙은 채 그 끝 안에서 위치가 정해지므로 닫히는 내내 잘리지 않는다.
struct IslandSurface<Card: View, Head: View>: View, Animatable {
    var data: IslandAnim
    @ViewBuilder let card: (IslandEnds) -> Card
    @ViewBuilder let head: (IslandEnds) -> Head
    let notchHeight: CGFloat
    var animatableData: IslandAnim { get { data } set { data = newValue } }

    var body: some View {
        let e = IslandGeometry.ends(data.shape, progress: data.progress)
        if IslandModel.traceOn {
            print(String(format: "FRAME %.4f %.2f %.2f L%.2f R%.2f HL%.2f HR%.2f P%.4f", ProcessInfo.processInfo.systemUptime,
                         e.left + e.right, e.height, e.left, e.right, e.headLeft, e.headRight, data.progress)); fflush(stdout)
        }
        return ZStack(alignment: .topLeading) {
            notchShape(CGFloat(e.radius)).fill(Color.black)
            card(e)
                .frame(width: IslandLayout.cardWidth, alignment: .top)
                .padding(.top, notchHeight)
                .offset(x: CGFloat(e.left) - IslandLayout.cardWidth / 2)
            head(e)
                .frame(width: CGFloat(e.headLeft + e.headRight), height: notchHeight, alignment: .topLeading)
                .offset(x: CGFloat(e.left - e.headLeft))
        }
        .frame(width: CGFloat(e.left + e.right), height: CGFloat(e.height), alignment: .topLeading)
        .clipShape(notchShape(CGFloat(e.radius)))
        .offset(x: CGFloat(e.right - e.left) / 2)
    }
}

/// 머리줄: 카메라 영역(가운데)을 비우고 양옆 같은 폭의 날개에 아이콘+값만 촘촘히 둔다(칸 사이 = 간격 토큰 하나).
/// 왼쪽 날개 = CPU / 오른쪽 날개 = 메모리 % · 압박 모양 | 열 모양 | 진행 링. 펼치면 날개가 넓어지고 각 칸이 자기 단어만큼 벌어지며
/// 단어가 페이드인한다(섬 펼침 애니메이션과 한 덩어리). 오른쪽이 넘치면 메모리 칸이 왼쪽 CPU 옆으로 간다.
struct HeadStrip: View {
    @ObservedObject var model: IslandModel
    let wingLeft: CGFloat          // 날개 폭 — 섬 끝과 같은 진행도로 보간된 값(IslandGeometry)
    let wingRight: CGFloat
    let notchWidth: CGFloat

    private static func traceWing(_ w: CGFloat) {
        guard IslandModel.traceOn else { return }
        print(String(format: "WING %.4f %.2f", ProcessInfo.processInfo.systemUptime, w)); fflush(stdout)
    }

    var body: some View {
        let _ = Self.traceWing(wingLeft)
        let mem = model.display(.memory), th = model.display(.thermal)
        let onRight = model.memorySide == .right
        let sp = HeadSpacing.at(open: model.phase.isOpen)
        HStack(spacing: 0) {
            HStack(spacing: sp.slotGap) {
                SlotView(model: model, kind: .cpu)
                if !onRight { MemoryGroup(model: model).transition(.opacity) }
            }
            .padding(.leading, sp.wingPad).frame(width: wingLeft, alignment: .leading)

            Color.clear.frame(width: notchWidth)         // 카메라 영역: 아무것도 그리지 않는다

            HStack(spacing: sp.slotGap) {
                if onRight { MemoryGroup(model: model).transition(.opacity) }
                HStack(spacing: 0) {
                    SlotView(model: model, kind: .thermal)
                    WordSlot(model: model, text: th.checking ? "" : th.value)
                }
                if let job = model.job {
                    HStack(spacing: 0) {
                        JobPod(model: model, job: job)
                        WordSlot(model: model, text: model.jobLabelText(job))
                    }
                    .padding(.leading, sp.ringGap - sp.slotGap)        // 온도 ↔ 링 간격만 더 넓다
                }
            }
            .padding(.leading, sp.wingPad).frame(width: wingRight, alignment: .leading)
        }
        .animation(model.reduceMotion ? nil : .easeOut(duration: 0.2), value: onRight)
        .contentShape(Rectangle())
        .onTapGesture { model.click(.head) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notch Island 상태 모니터")
        .accessibilityHint("누르면 펼침을 고정하고, 다시 누르면 접습니다")
        .accessibilityValue(mem.spoken)
    }
}

/// 메모리 칸: 아이콘 · % · 압박 모양 + (펼침에서만) 단계 단어.
struct MemoryGroup: View {
    @ObservedObject var model: IslandModel
    var body: some View {
        let mem = model.display(.memory)
        HStack(spacing: 0) {
            SlotView(model: model, kind: .memory)
            WordSlot(model: model, text: mem.checking ? "" : mem.value)
        }
    }
}
