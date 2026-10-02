import Foundation

/// 안 4 "타이핑 + 해독" 연출의 시간 계산(UI 독립 — 시안 `reveal` 의 수치 그대로).
/// 줄마다 시작이 조금씩 늦고(70ms + 줄 순번 × 9ms), 글자 폭 계단(7.2pt 칸)으로 드러나며, 막 드러난 글자는 0.14초 동안 가타카나였다가 진짜 글자로 굳는다.
public enum RevealTiming {
    /// 12pt 고정폭 글자 한 칸(시안 기준 7.2px)
    public static let cellWidth: Double = 7.2
    /// 카드 줄 타이핑 속도: 시안 3.4px/ms
    public static let cardCharsPerSecond: Double = 3400 / cellWidth
    /// 알림 문구 타이핑 속도: 시안 1.4px/ms
    public static let pillCharsPerSecond: Double = 1400 / cellWidth
    public static let firstLineStart: Double = 0.070
    public static let lineStagger: Double = 0.009
    /// 드러난 글자가 진짜 글자가 되기까지(그 전에는 가타카나)
    public static let settleLag: Double = 0.14
    /// 창틀(구분선) 그어지는 시간
    public static let ruleDuration: Double = 0.20
    /// 카드 연출 전체(코드 비 지속 시간과 같다) — 이후엔 시계를 멈춘다
    public static let cardTotal: Double = 0.95
    /// 알림 글리치 길이
    public static let glitchDuration: Double = 0.20
    /// 알림 문구 뒤 블록 커서가 깜빡이는 시간
    public static let pillCaretLinger: Double = 1.1
    public static let pillCaretPeriod: Double = 0.53

    /// 줄 순번(`order`)이 시작하는 시각(초, 펼침 기준)
    public static func lineStart(order: Int) -> Double { firstLineStart + lineStagger * Double(order) }

    /// `elapsed`(이 줄이 시작한 뒤 지난 초)에 드러난 글자 수. 무한대면 전부.
    public static func revealedCount(chars: Int, elapsed: Double, charsPerSecond cps: Double = cardCharsPerSecond) -> Int {
        if elapsed.isInfinite { return elapsed > 0 ? chars : 0 }
        guard elapsed > 0, chars > 0 else { return 0 }
        return min(chars, Int(elapsed * cps))
    }

    /// 진짜 글자로 굳은 글자 수(드러난 지 `settleLag` 가 지난 것만)
    public static func settledCount(chars: Int, elapsed: Double, charsPerSecond cps: Double = cardCharsPerSecond) -> Int {
        revealedCount(chars: chars, elapsed: elapsed - settleLag, charsPerSecond: cps)
    }

    /// 타이핑이 끝났나(전부 드러남)
    public static func isTyped(chars: Int, elapsed: Double, charsPerSecond cps: Double = cardCharsPerSecond) -> Bool {
        revealedCount(chars: chars, elapsed: elapsed, charsPerSecond: cps) >= chars
    }

    /// 전부 굳었나 — 이때부터 화면 글자는 실제 글자뿐이다
    public static func isSettled(chars: Int, elapsed: Double, charsPerSecond cps: Double = cardCharsPerSecond) -> Bool {
        settledCount(chars: chars, elapsed: elapsed, charsPerSecond: cps) >= chars
    }

    /// 한 줄이 전부 굳기까지 걸리는 시간(그 줄 시작 기준)
    public static func settleDuration(chars: Int, charsPerSecond cps: Double = cardCharsPerSecond) -> Double {
        Double(chars) / cps + settleLag
    }

    /// 창틀 선이 그어진 비율 0...1 (ease-out)
    public static func ruleProgress(elapsed: Double) -> Double {
        if elapsed.isInfinite { return elapsed > 0 ? 1 : 0 }
        let x = min(1, max(0, elapsed / ruleDuration))
        return 1 - pow(1 - x, 3)
    }

    /// 알림 글리치 단계(40ms 마다 한 단계, 0...4). 글리치가 끝났거나 시작 전이면 nil.
    public static func glitchStep(elapsed: Double) -> Int? {
        guard elapsed >= 0, elapsed < glitchDuration else { return nil }
        return Int(elapsed / (glitchDuration / 5))
    }

    /// 알림 연출 전체 길이: 타이핑(+굳음) 뒤 커서가 잠깐 더 깜빡이다 멈춘다. 이후엔 시계를 멈춘다.
    public static func pillTotal(chars: Int) -> Double {
        max(glitchDuration, settleDuration(chars: chars, charsPerSecond: pillCharsPerSecond) + pillCaretLinger)
    }
}

/// 해독 중 잠깐 보이는 가타카나. 숫자·영문은 반각, 한글은 전각(한글이 차지한 폭을 유지), 그 밖(기호·공백)은 그대로.
public enum GlyphScramble {
    private static let half = Array("ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ")
    private static let full = Array("アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワン")

    public static func isHangul(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value, c.unicodeScalars.count == 1 else { return false }
        return (0xAC00...0xD7A3).contains(v) || (0x3131...0x318E).contains(v)
    }

    public static func isScrambled(_ c: Character) -> Bool {
        (c.isASCII && (c.isLetter || c.isNumber)) || isHangul(c)
    }

    public static func char(for c: Character, seed: Int) -> Character {
        let pool: [Character]
        if c.isASCII && (c.isLetter || c.isNumber) { pool = half }
        else if isHangul(c) { pool = full }
        else { return c }
        let n = pool.count
        return pool[((seed % n) + n) % n]
    }

    /// `chars[settled..<revealed]` 구간만 섞어 돌려준다(앞은 진짜 글자, 뒤는 아직 안 드러남 — 호출자가 처리).
    public static func scrambled(_ chars: ArraySlice<Character>, startIndex: Int, tick: Int) -> String {
        var out = ""
        for (k, c) in chars.enumerated() {
            out.append(char(for: c, seed: (startIndex + k) * 31 + tick * 13))
        }
        return out
    }
}
