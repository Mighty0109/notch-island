import Foundation
import CoreGraphics

/// 머리줄 간격 토큰 — 값은 여기 한 곳에만 둔다. 접힘은 촘촘하게, 펼침은 한 단계 여유 있게.
public struct HeadSpacing: Equatable {
    public var iconValue: CGFloat       // 아이콘 ↔ 값(또는 열 칸은 아이콘 ↔ 단계 모양)
    public var valueGlyph: CGFloat      // 값 ↔ 단계 모양(◇)
    public var glyphWord: CGFloat       // 모양 ↔ 단어 (그리고 링 ↔ 작업 라벨)
    public var slotGap: CGFloat         // 칸과 칸 사이
    public var ringGap: CGFloat         // 온도 ↔ 진행 링 (다른 칸 사이보다 넓다)
    public var wingPad: CGFloat         // 날개 안쪽(카메라 쪽)·바깥쪽 여백

    public init(iconValue: CGFloat, valueGlyph: CGFloat, glyphWord: CGFloat, slotGap: CGFloat, ringGap: CGFloat, wingPad: CGFloat) {
        self.iconValue = iconValue; self.valueGlyph = valueGlyph; self.glyphWord = glyphWord
        self.slotGap = slotGap; self.ringGap = ringGap; self.wingPad = wingPad
    }

    public static let collapsed = HeadSpacing(iconValue: 5, valueGlyph: 4, glyphWord: 5, slotGap: 14, ringGap: 20, wingPad: 10)
    public static let open = HeadSpacing(iconValue: 5, valueGlyph: 4, glyphWord: 5, slotGap: 18, ringGap: 24, wingPad: 14)

    public static func at(open: Bool) -> HeadSpacing { open ? .open : .collapsed }
}

/// 머리줄 각 요소의 글리프·글자 폭(뷰가 재서 넣는다). 간격은 `HeadSpacing` 이 정한다.
public struct HeadContentWidths: Equatable {
    public var cpuIcon: CGFloat, cpuValue: CGFloat
    public var memIcon: CGFloat, memValue: CGFloat, glyph: CGFloat
    public var thermIcon: CGFloat
    public var memWord: CGFloat, thermWord: CGFloat      // 0 = 단어 없음(확인 중)
    public var ring: CGFloat                              // 0 = 진행 작업 없음
    public var label: CGFloat                             // 링 뒤 작업 라벨 글자 폭
    public init(cpuIcon: CGFloat, cpuValue: CGFloat, memIcon: CGFloat, memValue: CGFloat, glyph: CGFloat, thermIcon: CGFloat,
                memWord: CGFloat, thermWord: CGFloat, ring: CGFloat, label: CGFloat) {
        self.cpuIcon = cpuIcon; self.cpuValue = cpuValue; self.memIcon = memIcon; self.memValue = memValue; self.glyph = glyph
        self.thermIcon = thermIcon; self.memWord = memWord; self.thermWord = thermWord; self.ring = ring; self.label = label
    }
}

/// 날개 폭 계산 — 좌우 대칭이라 큰 쪽 내용 폭에 맞춘다.
public enum HeadSizing {
    /// 오른쪽 내용 폭 상한(펼침 기준): 넘치면 메모리 칸이 왼쪽으로 간다
    public static let rightBudget: CGFloat = 300

    private static func joined(_ parts: [CGFloat], gap: CGFloat) -> CGFloat {
        let present = parts.filter { $0 > 0 }
        return present.reduce(0, +) + gap * CGFloat(max(0, present.count - 1))
    }

    public static func cpu(_ w: HeadContentWidths, _ s: HeadSpacing) -> CGFloat { w.cpuIcon + s.iconValue + w.cpuValue }

    public static func memory(_ w: HeadContentWidths, _ s: HeadSpacing, open: Bool) -> CGFloat {
        w.memIcon + s.iconValue + w.memValue + s.valueGlyph + w.glyph + (open && w.memWord > 0 ? s.glyphWord + w.memWord : 0)
    }

    public static func thermal(_ w: HeadContentWidths, _ s: HeadSpacing, open: Bool) -> CGFloat {
        w.thermIcon + s.iconValue + w.glyph + (open && w.thermWord > 0 ? s.glyphWord + w.thermWord : 0)
    }

    public static func ring(_ w: HeadContentWidths, _ s: HeadSpacing, open: Bool) -> CGFloat {
        w.ring > 0 ? w.ring + (open && w.label > 0 ? s.glyphWord + w.label : 0) : 0
    }

    public static func leftContent(_ w: HeadContentWidths, side: MemorySlotFlow.Side, open: Bool) -> CGFloat {
        let s = HeadSpacing.at(open: open)
        return joined([cpu(w, s), side == .left ? memory(w, s, open: open) : 0], gap: s.slotGap)
    }

    /// 오른쪽 내용: [메모리] · 열 · 링. 열↔링 간격만 `ringGap`(더 넓음), 나머지 칸 사이는 `slotGap`.
    private static func rightJoin(mem: CGFloat, therm: CGFloat, ring: CGFloat, _ s: HeadSpacing) -> CGFloat {
        var total = therm
        if mem > 0 { total += mem + s.slotGap }
        if ring > 0 { total += s.ringGap + ring }
        return total
    }

    public static func rightContent(_ w: HeadContentWidths, side: MemorySlotFlow.Side, open: Bool) -> CGFloat {
        let s = HeadSpacing.at(open: open)
        return rightJoin(mem: side == .right ? memory(w, s, open: open) : 0, therm: thermal(w, s, open: open), ring: ring(w, s, open: open), s)
    }

    /// 메모리 칸을 뺀 오른쪽 내용 폭(열·링…) — 접힘/펼침 상태별
    public static func rightWithoutMemory(_ w: HeadContentWidths, open: Bool) -> CGFloat {
        let s = HeadSpacing.at(open: open)
        return rightJoin(mem: 0, therm: thermal(w, s, open: open), ring: ring(w, s, open: open), s)
    }

    /// 메모리 칸을 뺀 오른쪽 펼침 내용 폭 — 예산 안전장치용
    public static func rightOpenWithoutMemory(_ w: HeadContentWidths) -> CGFloat { rightWithoutMemory(w, open: true) }

    /// 날개 폭 = 각자 내용 폭 + 양쪽 여백 (좌우 비대칭 허용 — 빈 검은 부분을 만들지 않는다)
    public static func wings(_ w: HeadContentWidths, side: MemorySlotFlow.Side, open: Bool) -> (left: CGFloat, right: CGFloat) {
        let s = HeadSpacing.at(open: open)
        return (s.wingPad + leftContent(w, side: side, open: open) + s.wingPad,
                s.wingPad + rightContent(w, side: side, open: open) + s.wingPad)
    }
}
