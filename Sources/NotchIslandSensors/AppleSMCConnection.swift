import Foundation
import IOKit

/// AppleSMC 에 사용자 권한으로 연결해 **읽기만** 한다. 쓰는 SMC 명령은 이 파일에 존재하지 않는다.
/// 쓰는 명령: 5(키 값 읽기) · 8(인덱스로 키 이름) · 9(키 정보) 세 가지뿐.
/// 구조체 배치(80바이트, 호스트 엔디언): 0 key · 28 keyInfo{size@28, type@32, attr@36} · 40 result · 42 command · 44 index · 48..79 bytes.
public final class AppleSMCConnection: SMCSource {
    private static let structSize = 80
    private static let cmdReadBytes: UInt8 = 5
    private static let cmdReadIndex: UInt8 = 8
    private static let cmdReadKeyInfo: UInt8 = 9
    private static let selector: UInt32 = 2

    private struct KeyInfo { var size: UInt32; var type: String }

    private var conn: io_connect_t = 0
    private var infoCache: [String: KeyInfo] = [:]

    /// SMC 를 못 열면 nil (미지원 · 권한 거부).
    public init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS, conn != 0 else { return nil }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    public func keyCount() -> Int? {
        guard let v = read("#KEY"), let n = SMCDecode.number(v), n >= 0 else { return nil }
        return Int(n)
    }

    public func key(at index: Int) -> String? {
        var b = [UInt8](repeating: 0, count: Self.structSize)
        b[42] = Self.cmdReadIndex
        putNative32(&b, 44, UInt32(truncatingIfNeeded: index))
        guard let out = call(b), out[40] == 0 else { return nil }
        return Self.fourCCString(getNative32(out, 0))
    }

    public func read(_ key: String) -> SMCValue? {
        guard let info = keyInfo(key) else { return nil }
        var b = [UInt8](repeating: 0, count: Self.structSize)
        putNative32(&b, 0, Self.fourCC(key))
        putNative32(&b, 28, info.size)
        b[42] = Self.cmdReadBytes
        guard let out = call(b), out[40] == 0 else { return nil }
        let n = Int(min(info.size, 32))
        return SMCValue(type: info.type, bytes: Array(out[48..<(48 + n)]))
    }

    // MARK: 낮은 층

    private func keyInfo(_ key: String) -> KeyInfo? {
        if let c = infoCache[key] { return c }
        var b = [UInt8](repeating: 0, count: Self.structSize)
        putNative32(&b, 0, Self.fourCC(key))
        b[42] = Self.cmdReadKeyInfo
        guard let out = call(b), out[40] == 0 else { return nil }
        let info = KeyInfo(size: getNative32(out, 28), type: Self.fourCCString(getNative32(out, 32)))
        infoCache[key] = info
        return info
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var inp = input
        var out = [UInt8](repeating: 0, count: Self.structSize)
        var outSize = Self.structSize
        let kr = inp.withUnsafeMutableBytes { ip in
            out.withUnsafeMutableBytes { op in
                IOConnectCallStructMethod(conn, Self.selector, ip.baseAddress, Self.structSize, op.baseAddress, &outSize)
            }
        }
        return kr == KERN_SUCCESS ? out : nil
    }

    private func putNative32(_ b: inout [UInt8], _ off: Int, _ v: UInt32) {
        b[off] = UInt8(v & 0xff); b[off + 1] = UInt8((v >> 8) & 0xff)
        b[off + 2] = UInt8((v >> 16) & 0xff); b[off + 3] = UInt8((v >> 24) & 0xff)
    }

    private func getNative32(_ b: [UInt8], _ off: Int) -> UInt32 {
        UInt32(b[off]) | UInt32(b[off + 1]) << 8 | UInt32(b[off + 2]) << 16 | UInt32(b[off + 3]) << 24
    }

    private static func fourCC(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for c in s.utf8.prefix(4) { v = (v << 8) | UInt32(c) }
        return v
    }

    private static func fourCCString(_ v: UInt32) -> String {
        let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(decoding: bytes.map { ($0 >= 32 && $0 < 127) ? $0 : 63 }, as: UTF8.self)
    }
}
