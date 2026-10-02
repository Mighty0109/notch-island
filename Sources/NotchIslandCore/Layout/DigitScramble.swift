import Foundation

/// 매트릭스 숫자 해독 효과의 프레임 계산(UI 독립). 바뀐 숫자 자리만 섞였다가 목표 값으로 굳는다.
/// 숫자 자리에는 숫자(또는 가타카나)만, 그 밖의 글자(%, —, 공백)는 절대 건드리지 않으므로 중간 프레임이 찍혀도 `C%` 같은 글자가 나올 수 없다.
public enum DigitScramble {
    public static let steps = 2

    /// - Parameters:
    ///   - step: 0..<steps 는 섞인 프레임, steps 이상이면 항상 `target` 그대로.
    ///   - random: 0...9 를 돌려주는 난수원(테스트에서 고정 가능)
    public static func frame(old: String, target: String, step: Int, random: () -> Int) -> String {
        guard step < steps else { return target }
        let o = Array(old), t = Array(target)
        var out = t
        for i in t.indices where isDigit(t[i]) && (i >= o.count || o[i] != t[i]) {
            out[i] = Character(String(min(9, max(0, random()))))
        }
        return String(out)
    }

    // MARK: 가타카나 해독 (안 4) — 바뀐 숫자 자리만 가타카나로 섞였다가 **앞자리부터** 숫자로 굳는다.

    /// 바뀐 숫자 자리의 번호(왼쪽부터 0). 이 자리들만 섞인다.
    public static func changedDigitSlots(old: String, target: String) -> [Int] {
        let o = Array(old), t = Array(target)
        return t.indices.filter { isDigit(t[$0]) && ($0 >= o.count || o[$0] != t[$0]) }
    }

    /// 해독에 걸리는 단계 수: 가장 오른쪽 바뀐 자리가 굳는 단계 + 1. 바뀐 자리가 없으면 0.
    public static func kanaSteps(old: String, target: String) -> Int {
        let n = changedDigitSlots(old: old, target: target).count
        return n == 0 ? 0 : n + 1
    }

    /// `step` 번째 프레임. 바뀐 숫자 중 앞에서 r 번째 자리는 `step >= r + 1` 이면 목표 숫자, 아니면 가타카나. 끝(`kanaSteps` 이상)은 항상 `target`.
    public static func kanaFrame(old: String, target: String, step: Int, seed: Int) -> String {
        let slots = changedDigitSlots(old: old, target: target)
        guard !slots.isEmpty, step < slots.count + 1 else { return target }
        var out = Array(target)
        for (rank, i) in slots.enumerated() where step < rank + 1 {
            out[i] = GlyphScramble.char(for: "0", seed: (seed + i) * 7 + step * 11 + 3)
        }
        return String(out)
    }

    private static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
}
