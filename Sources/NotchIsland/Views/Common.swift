import SwiftUI
import NotchIslandCore

/// 아래쪽 모서리만 둥근 섬 모양. 위쪽은 화면 가장자리·하드웨어 노치와 이어진다.
func notchShape(_ r: CGFloat) -> UnevenRoundedRectangle {
    UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: r, bottomTrailing: r, topTrailing: 0), style: .continuous)
}

/// 값이 바뀌면 바뀐 숫자 자리만 가타카나로 섞였다가 앞자리부터 숫자로 굳는 매트릭스식 해독 효과(안 4). reduced-motion 이면 그냥 바꾼다.
/// 섞인 프레임은 `scramble` 로만 표시하고 취소·종료 때 반드시 비워서(defer) 최종 값은 항상 `text` 가 보인다(숫자 자리 최종은 숫자).
struct ScrambleText: View {
    let text: String
    let font: Font
    let color: Color
    let reduceMotion: Bool
    @State private var scramble: String?
    @State private var previous = ""

    var body: some View {
        Text(scramble ?? text)
            .font(font).foregroundColor(color).lineLimit(1).fixedSize()     // 칸 폭(frame)보다 글자가 살짝 넓어도 "…" 로 잘리지 않게
            .task(id: text) { await decode() }
    }

    private func decode() async {
        defer { scramble = nil; previous = text }
        guard !reduceMotion, !previous.isEmpty, previous != text else { return }
        let seed = Int.random(in: 0..<10_000)
        for step in 0..<DigitScramble.kanaSteps(old: previous, target: text) {
            scramble = DigitScramble.kanaFrame(old: previous, target: text, step: step, seed: seed)
            try? await Task.sleep(nanoseconds: 55_000_000)
            if Task.isCancelled { return }
        }
    }
}

func formatRate(_ bytesPerSec: Double) -> String {
    if bytesPerSec >= 1_000_000 { return String(format: "%.1fMB/s", bytesPerSec / 1_000_000) }
    if bytesPerSec >= 1_000 { return String(format: "%.0fKB/s", bytesPerSec / 1_000) }
    return String(format: "%.0fB/s", bytesPerSec)
}
