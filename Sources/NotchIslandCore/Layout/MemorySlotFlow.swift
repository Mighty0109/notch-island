import Foundation
import CoreGraphics

/// 메모리 칸이 어느 날개에 앉을지 — 좌우 균형으로 정한다.
/// A = 왼쪽[CPU] / 오른쪽[메모리·열·링…], B = 왼쪽[CPU·메모리] / 오른쪽[열·링…].
/// |좌−우| 가 더 작은 배치를 고른다(동률이면 B)(날개 폭 = max(좌,우) 라 균형 배치가 섬 폭도 줄인다).
/// 안전장치: 펼침 기준 오른쪽(A) 내용이 예산을 넘으면 B.
/// 깜빡임 방지: A→B 는 즉시, B→A 는 A 가 `returnMargin` 이상 더 균형적인 상태가 `returnHold` 초 넘게 이어질 때만.
/// UI 독립: 폭은 뷰가 측정해서 넣는다.
public struct MemorySlotFlow: Equatable {
    public enum Side: Equatable, Sendable { case right, left }

    public static let returnMargin: CGFloat = 16
    public static let returnHold: TimeInterval = 1.0

    public private(set) var side: Side = .right
    private var roomSince: TimeInterval?

    public init() {}

    /// - Parameters:
    ///   - cpuLeft: 왼쪽 날개의 CPU 칸 폭(현재 상태: 접힘/펼침 폭)
    ///   - memory: 메모리 칸 폭(같은 상태)
    ///   - rightWithoutMemory: 메모리를 뺀 오른쪽 내용 폭(열·링…, 없으면 0)
    ///   - gap: 칸 사이 간격
    ///   - rightAOpen: 메모리가 오른쪽일 때의 오른쪽 **펼침** 폭 — 예산 안전장치용
    ///   - budget: 오른쪽 내용 폭 상한
    @discardableResult
    public mutating func update(cpuLeft: CGFloat, memory: CGFloat, rightWithoutMemory: CGFloat, gap: CGFloat,
                                rightAOpen: CGFloat, budget: CGFloat, now t: TimeInterval) -> Side {
        let leftA = cpuLeft
        let rightA = rightWithoutMemory > 0 ? rightWithoutMemory + gap + memory : memory
        let leftB = cpuLeft + gap + memory
        let rightB = rightWithoutMemory
        let diffA = abs(leftA - rightA), diffB = abs(leftB - rightB)
        let overflow = rightAOpen > budget

        switch side {
        case .right:
            if overflow || diffB <= diffA { side = .left; roomSince = nil }      // 동률이면 왼쪽(링이 있는 전형적인 접힘)
        case .left:
            if !overflow, diffB - diffA >= Self.returnMargin {
                if roomSince == nil { roomSince = t }
                if let s = roomSince, t - s >= Self.returnHold { side = .right; roomSince = nil }
            } else {
                roomSince = nil
            }
        }
        return side
    }

    /// 배치 판정은 **접힘 폭 기준으로 고정** — 펼침은 접힘에서 정해진 배치를 그대로 따른다(펼침 중 재판정 없음, 단어 폭이 판정에 안 섞인다).
    /// 예외는 안전장치뿐: 펼침 기준 오른쪽(A) 내용이 예산을 넘으면 B.
    @discardableResult
    public mutating func update(widths full: HeadContentWidths, now t: TimeInterval) -> Side {
        let w = full.withoutItemLabels            // 펼침 라벨(cpu·mem·temp)은 배치 판정에 안 섞인다 — 라벨 때문에 메모리 칸이 옮겨가면 안 된다
        let c = HeadSpacing.collapsed, o = HeadSpacing.open
        let rightOpenNoMem = HeadSizing.rightOpenWithoutMemory(w)
        let memOpen = HeadSizing.memory(w, o, open: true)
        return update(cpuLeft: HeadSizing.cpu(w, c), memory: HeadSizing.memory(w, c, open: false),
                      rightWithoutMemory: HeadSizing.rightWithoutMemory(w, open: false), gap: c.slotGap,
                      rightAOpen: rightOpenNoMem > 0 ? rightOpenNoMem + o.slotGap + memOpen : memOpen,
                      budget: HeadSizing.rightBudget, now: t)
    }
}
