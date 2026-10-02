import Foundation
import Darwin

public struct InterfaceCounters: Equatable, Sendable {
    public var rx: UInt64, tx: UInt64
    public init(rx: UInt64, tx: UInt64) { self.rx = rx; self.tx = tx }
}

/// 누적 바이트 차분 / 경과 시간. 기준점만 잡아야 하는 경우(첫 샘플·긴 공백·인터페이스 변동·카운터 리셋)를 처리한다.
public struct NetworkRateCalculator {
    public var maxGapSeconds: Double
    private var prev: [String: InterfaceCounters]?
    private var prevNs: UInt64?

    public init(maxGapSeconds: Double = 10) { self.maxGapSeconds = maxGapSeconds }

    public mutating func reset() { prev = nil; prevNs = nil }

    /// - Parameter nowNs: 잠자기 시간을 포함하는 단조 시계(ns).
    public mutating func update(counters: [String: InterfaceCounters], nowNs: UInt64) -> NetworkRate? {
        defer { prev = counters; prevNs = nowNs }
        guard let p = prev, let pn = prevNs, nowNs > pn else { return nil }
        let dt = Double(nowNs - pn) / 1_000_000_000
        // 잠자기 복귀·긴 정지 뒤 첫 샘플은 가짜 급등의 원인 → 기준점으로만 쓴다
        guard dt <= maxGapSeconds else { return nil }
        var down: UInt64 = 0, up: UInt64 = 0
        var used = false
        for (name, c) in counters {
            guard let o = p[name] else { continue }                // 새로 나타난 인터페이스는 기준점만
            guard c.rx >= o.rx, c.tx >= o.tx else { continue }      // 카운터 리셋·랩: 이 샘플은 건너뜀
            down += c.rx - o.rx
            up += c.tx - o.tx
            used = true
        }
        guard used else { return nil }
        return NetworkRate(downBytesPerSec: Double(down) / dt, upBytesPerSec: Double(up) / dt)
    }
}

public protocol NetworkCounterSource {
    func readCounters() -> [String: InterfaceCounters]?
}

/// getifaddrs 의 AF_LINK 항목. 물리 인터페이스(en*)만 합산해 VPN(utun)·가상 인터페이스 중복 집계를 피한다.
public struct GetIfAddrsCounterSource: NetworkCounterSource {
    public init() {}
    public func readCounters() -> [String: InterfaceCounters]? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var out: [String: InterfaceCounters] = [:]
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cur {
            defer { cur = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en"), let raw = ifa.pointee.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            out[name] = InterfaceCounters(rx: UInt64(data.ifi_ibytes), tx: UInt64(data.ifi_obytes))
        }
        return out
    }
}

public enum MonotonicClock {
    /// 잠자기 시간을 포함하는 단조 시계 (CLOCK_MONOTONIC).
    public static func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC) }
}

public final class NetworkProvider {
    private let source: NetworkCounterSource
    private var calc = NetworkRateCalculator()
    public init(source: NetworkCounterSource = GetIfAddrsCounterSource()) { self.source = source }

    public func reset() { calc.reset() }

    public func sample(now: Date, nowNs: UInt64 = MonotonicClock.nowNs()) -> Reading<NetworkRate> {
        let src = "getifaddrs(en*)"
        guard let counters = source.readCounters() else {
            calc.reset()
            return .failed("읽기 실패", unit: "B/s", at: now, source: src)
        }
        if let r = calc.update(counters: counters, nowNs: nowNs) {
            return .ok(r, unit: "B/s", at: now, source: src)
        }
        return .checking(unit: "B/s", at: now, source: src)
    }
}
