import Foundation

/// SMC 키 하나의 원시 값. `type` 은 SMC 의 4글자 타입(`flt` · `ui8` …), `bytes` 는 SMC 가 준 그대로.
public struct SMCValue: Equatable, Sendable {
    public var type: String
    public var bytes: [UInt8]
    public init(type: String, bytes: [UInt8]) { self.type = type; self.bytes = bytes }
}

/// 읽기 전용 SMC 접근. 실기는 `AppleSMCConnection`, 테스트는 가짜 구현을 주입한다.
public protocol SMCSource: AnyObject {
    /// 전체 키 개수(`#KEY`). 못 읽으면 nil.
    func keyCount() -> Int?
    /// 인덱스로 키 이름 열거. 못 읽으면 nil.
    func key(at index: Int) -> String?
    /// 키 값 읽기. 없는 키·읽기 실패는 nil.
    func read(_ key: String) -> SMCValue?
}

/// SMC 값을 숫자로. 알려진 타입만 풀고 나머지는 nil. (Apple Silicon 은 온도·RPM 이 `flt`, 개수가 `ui8`)
public enum SMCDecode {
    public static func number(_ v: SMCValue) -> Double? {
        let b = v.bytes
        switch v.type.trimmingCharacters(in: .whitespaces) {
        case "flt":
            guard b.count >= 4 else { return nil }
            let raw = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24      // 리틀엔디언
            let f = Float(bitPattern: raw)
            return f.isFinite ? Double(f) : nil
        case "ui8":
            return b.count >= 1 ? Double(b[0]) : nil
        case "ui16":
            return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) : nil
        case "ui32":
            guard b.count >= 4 else { return nil }
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        default:
            return nil
        }
    }
}
