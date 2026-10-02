import Foundation
import Darwin

public struct ProcessSample: Equatable, Sendable {
    public var pid: Int32
    public var name: String
    public var cpuTimeNs: UInt64          // 누적 user+system CPU 시간(ns)
    public var residentBytes: UInt64
    public init(pid: Int32, name: String, cpuTimeNs: UInt64, residentBytes: UInt64) {
        self.pid = pid; self.name = name; self.cpuTimeNs = cpuTimeNs; self.residentBytes = residentBytes
    }
}

public enum ProcessMath {
    /// 두 시점의 누적 CPU 시간 차분 → 프로세스별 % (코어 1개 = 100%). 같은 이름은 합친다.
    /// 이전 샘플에 없던 pid 는 기준점만(급등 방지). 누적 시간이 줄었으면(pid 재사용) 건너뜀.
    public static func topUsage(prev: [Int32: UInt64], cur: [ProcessSample], dtSeconds: Double, limit: Int) -> [ProcessUsage] {
        guard dtSeconds > 0 else { return [] }
        var byName: [String: (cpu: Double, rss: UInt64, n: Int)] = [:]
        for s in cur {
            guard let before = prev[s.pid], s.cpuTimeNs >= before else { continue }
            let pct = Double(s.cpuTimeNs - before) / 1_000_000_000 / dtSeconds * 100
            var e = byName[s.name] ?? (0, 0, 0)
            e.cpu += pct; e.rss += s.residentBytes; e.n += 1
            byName[s.name] = e
        }
        var list: [ProcessUsage] = []
        for (name, e) in byName {
            list.append(ProcessUsage(name: name, cpuPercent: e.cpu, residentBytes: e.rss, count: e.n))
        }
        list.sort { (a: ProcessUsage, b: ProcessUsage) -> Bool in
            if a.cpuPercent != b.cpuPercent { return a.cpuPercent > b.cpuPercent }
            return a.name < b.name
        }
        return Array(list.prefix(limit))
    }
}

public protocol ProcessSource {
    func readAll() -> [ProcessSample]?
}

/// libproc. 같은 사용자의 프로세스만 읽히므로 "읽을 수 있는 프로세스 기준" 순위다.
public struct LibprocSource: ProcessSource {
    private let numer: UInt64, denom: UInt64
    public init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        numer = UInt64(tb.numer == 0 ? 1 : tb.numer); denom = UInt64(tb.denom == 0 ? 1 : tb.denom)
    }

    public func readAll() -> [ProcessSample]? {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 32)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return nil }
        let n = Int(got) / MemoryLayout<pid_t>.size
        var out: [ProcessSample] = []
        out.reserveCapacity(n)
        var nameBuf = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(n) where pid > 0 {
            var ti = proc_taskinfo()
            let r = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size))
            guard r == Int32(MemoryLayout<proc_taskinfo>.size) else { continue }
            let ticks = ti.pti_total_user &+ ti.pti_total_system
            let ns = ticks &* numer / denom
            let len = proc_name(pid, &nameBuf, UInt32(nameBuf.count))
            let name = len > 0 ? String(cString: nameBuf) : "pid \(pid)"
            out.append(ProcessSample(pid: pid, name: name, cpuTimeNs: ns, residentBytes: ti.pti_resident_size))
        }
        return out
    }
}

/// 상위 프로세스 수집기. 펼침일 때만 호출한다(전체 pid 조사 비용).
public final class ProcessProvider {
    private let source: ProcessSource
    private var prev: [Int32: UInt64]?
    private var prevNs: UInt64?
    public var maxGapSeconds: Double = 10

    public init(source: ProcessSource = LibprocSource()) { self.source = source }
    public func reset() { prev = nil; prevNs = nil }

    public func sample(now: Date, nowNs: UInt64 = MonotonicClock.nowNs(), limit: Int = 5) -> Reading<[ProcessUsage]> {
        let src = "libproc(읽을 수 있는 프로세스만)"
        guard let all = source.readAll() else {
            reset()
            return .failed("읽기 실패", unit: "%", at: now, source: src)
        }
        let table = Dictionary(all.map { ($0.pid, $0.cpuTimeNs) }, uniquingKeysWith: { a, _ in a })
        defer { prev = table; prevNs = nowNs }
        guard let p = prev, let pn = prevNs, nowNs > pn else { return .checking(unit: "%", at: now, source: src) }
        let dt = Double(nowNs - pn) / 1_000_000_000
        guard dt <= maxGapSeconds else { return .checking(unit: "%", at: now, source: src) }
        return .ok(ProcessMath.topUsage(prev: p, cur: all, dtSeconds: dt, limit: limit), unit: "%", at: now, source: src)
    }
}
