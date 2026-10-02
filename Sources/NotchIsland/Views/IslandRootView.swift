import SwiftUI
import NotchIslandCore

/// 패널 안의 모든 그림. 섬(접힘 ↔ 펼침 스프링), 물방울, 알약 글자를 한 좌표계에서 그린다.
struct IslandRootView: View {
    @ObservedObject var model: IslandModel
    @State private var cardVisible = false      // 마운트 직후 0 → 1 로 페이드인하기 위한 한 틱 지연

    var body: some View {
        let layout = model.layout
        let island = layout.island
        let isOpen = model.phase.isOpen
        let radius: CGFloat = isOpen ? 28 : 12
        let nh = layout.notchHeight

        ZStack(alignment: .topLeading) {
            if model.drop != .hidden, !isOpen {
                DropLayer(model: model, layout: layout)
            }

            ZStack(alignment: .top) {
                notchShape(radius).fill(Color.black)
                    .shadow(color: .black.opacity(isOpen ? 0.32 : 0), radius: 18, x: 0, y: 12)

                if model.cardMounted {
                    // 카드는 카메라(패널 가운데) 중심 720pt 고정 폭 — 머리줄이 더 넓어 섬이 양옆으로 더 뻗어도 카드는 그 안 가운데에 선다.
                    // 왼쪽 여백은 섬의 왼쪽 뻗음에 맞춰 같은 곡선으로 움직이므로 펼침·닫힘 중에도 카드가 제자리(카메라 기준)에 있다.
                    CardView(model: model)
                        .padding(.top, nh)
                        .frame(width: IslandLayout.cardWidth, height: island.height, alignment: .top)
                        .contentShape(Rectangle())
                        .onTapGesture { model.click(.card) }
                        .opacity(cardVisible ? 1 : 0)
                        .animation(model.reduceMotion ? nil : (cardVisible ? .easeOut(duration: 0.12) : .easeIn(duration: 0.09)), value: cardVisible)
                        .allowsHitTesting(isOpen)
                        .accessibilityHidden(!isOpen)
                        .padding(.leading, layout.extents.left - IslandLayout.cardWidth / 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                HeadStrip(model: model)
                    .frame(width: layout.head.width, height: nh)
                    .padding(.leading, layout.headXInIsland)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            // 섬 외곽: 카메라 기준 왼쪽·오른쪽 뻗음을 각각 애니메이션하고, 프레임마다 노치 하드웨어 폭·높이 미만을 잘라낸다
            .modifier(IslandFrame(left: layout.extents.left, right: layout.extents.right, h: island.height, radius: radius,
                                  minHalf: layout.notchWidth / 2, minH: nh))
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

/// 섬 외곽 애니메이션: 카메라(패널 가운데) 기준 왼쪽·오른쪽 뻗음 + 높이 + 모서리. 좌우가 각자 움직여 한쪽만 길어질 수 있고,
/// 프레임마다 노치 하드웨어 폭·높이 미만으로는 못 줄어든다(하드웨어 카메라가 드러나지 않게).
struct IslandFrame: ViewModifier, Animatable {
    var left: CGFloat
    var right: CGFloat
    var h: CGFloat
    var radius: CGFloat
    let minHalf: CGFloat
    let minH: CGFloat
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(left, right), AnimatablePair(h, radius)) }
        set { left = newValue.first.first; right = newValue.first.second; h = newValue.second.first; radius = newValue.second.second }
    }
    func body(content: Content) -> some View {
        let l = IslandMotion.clamped(left, min: minHalf), r = IslandMotion.clamped(right, min: minHalf)
        if IslandModel.traceOn { print(String(format: "FRAME %.4f %.2f %.2f L%.2f R%.2f", ProcessInfo.processInfo.systemUptime, l + r, h, l, r)); fflush(stdout) }
        return content
            .frame(width: l + r, height: IslandMotion.clamped(h, min: minH), alignment: .top)
            .clipShape(notchShape(radius))
            .offset(x: (r - l) / 2)
    }
}

/// 머리줄: 카메라 영역(가운데)을 비우고 양옆 같은 폭의 날개에 아이콘+값만 촘촘히 둔다(칸 사이 = 간격 토큰 하나).
/// 왼쪽 날개 = CPU / 오른쪽 날개 = 메모리 % · 압박 모양 | 열 모양 | 진행 링. 펼치면 날개가 넓어지고 각 칸이 자기 단어만큼 벌어지며
/// 단어가 페이드인한다(섬 펼침 애니메이션과 한 덩어리). 오른쪽이 넘치면 메모리 칸이 왼쪽 CPU 옆으로 간다.
struct HeadStrip: View {
    @ObservedObject var model: IslandModel

    private static func traceWing(_ w: CGFloat) {
        guard IslandModel.traceOn else { return }
        print(String(format: "WING %.4f %.2f", ProcessInfo.processInfo.systemUptime, w)); fflush(stdout)
    }

    var body: some View {
        let l = model.layout
        let _ = Self.traceWing(l.wings.left)
        let mem = model.display(.memory), th = model.display(.thermal)
        let onRight = model.memorySide == .right
        let sp = HeadSpacing.at(open: model.phase.isOpen)
        HStack(spacing: 0) {
            HStack(spacing: sp.slotGap) {
                SlotView(model: model, kind: .cpu)
                if !onRight { MemoryGroup(model: model).transition(.opacity) }
            }
            .padding(.leading, sp.wingPad).frame(width: l.wings.left, alignment: .leading)

            Color.clear.frame(width: l.notchWidth)         // 카메라 영역: 아무것도 그리지 않는다

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
            .padding(.leading, sp.wingPad).frame(width: l.wings.right, alignment: .leading)
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
