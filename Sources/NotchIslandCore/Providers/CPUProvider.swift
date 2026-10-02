import Foundation
import Darwin

/// 코어 1개의 누적 틱 (host_processor_info, 32비트 카운터).
public struct CoreTicks: Equatable, Sendable {
    public var user: UInt32, system: UInt32, idle: UInt32, nice: UInt32
    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }
}

public enum CPUMath {
    /// 두 시점 사이 코어별 사용률 0...1. 코어 수가 다르거나 경과 틱이 0이면 nil.
    /// 카운터는 UInt32 라서 `&-` (랩 어라운드 차분) 로 뺀다.
    public static func perCoreUsage(prev: [CoreTicks], cur: [CoreTicks]) -> [Double]? {
        guard prev.count == cur.count, !cur.isEmpty else { return nil }
        var out: [Double] = []
        out.reserveCapacity(cur.count)
        var anyDelta = false
        for (p, c) in zip(prev, cur) {
            let u = UInt64(c.user &- p.user), s = UInt64(c.system &- p.system)
            let i = UInt64(c.idle &- p.idle), n = UInt64(c.nice &- p.nice)
            let total = u + s + i + n
            if total > 0 { anyDelta = true }
            out.append(total == 0 ? 0 : min(1, max(0, Double(u + s + n) / Double(total))))
        }
        return anyDelta ? out : nil
    }

    /// 전체 CPU 용량 대비 사용률(%): 코어별 경과 틱을 가중 합산.
    public static func overallPercent(prev: [CoreTicks], cur: [CoreTicks]) -> Double? {
        guard prev.count == cur.count, !cur.isEmpty else { return nil }
        var busy: UInt64 = 0, total: UInt64 = 0
        for (p, c) in zip(prev, cur) {
            let u = UInt64(c.user &- p.user), s = UInt64(c.system &- p.system)
            let i = UInt64(c.idle &- p.idle), n = UInt64(c.nice &- p.nice)
            busy += u + s + n
            total += u + s + i + n
        }
        guard total > 0 else { return nil }
        return min(100, max(0, Double(busy) / Double(total) * 100))
    }
}

public protocol CPUTickSource {
    func readTicks() -> [CoreTicks]?
}

public struct HostCPUTickSource: CPUTickSource {
    public init() {}
    public func readTicks() -> [CoreTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var out: [CoreTicks] = []
        let stride = Int(CPU_STATE_MAX)
        for i in 0..<Int(cpuCount) {
            let base = i * stride
            out.append(CoreTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }
        return out
    }
}

/// CPU 수집기. 첫 샘플(또는 reset 직후)은 기준점만 잡고 "확인 중".
public final class CPUProvider {
    private let source: CPUTickSource
    private var prev: [CoreTicks]?

    public init(source: CPUTickSource = HostCPUTickSource()) { self.source = source }

    public func reset() { prev = nil }

    public func sample(now: Date) -> (overall: Reading<Double>, cores: Reading<CoreUsage>) {
        let src = "host_processor_info"
        guard let cur = source.readTicks() else {
            prev = nil
            return (.failed("읽기 실패", unit: "%", at: now, source: src),
                    .failed("읽기 실패", unit: "%", at: now, source: src))
        }
        defer { prev = cur }
        guard let p = prev,
              let per = CPUMath.perCoreUsage(prev: p, cur: cur),
              let all = CPUMath.overallPercent(prev: p, cur: cur) else {
            return (.checking(unit: "%", at: now, source: src), .checking(unit: "%", at: now, source: src))
        }
        return (.ok(all, unit: "%", at: now, source: src), .ok(CoreUsage(perCore: per), unit: "%", at: now, source: src))
    }
}

/// 코어 종류 개수 (hw.perflevelN). 코어 번호 ↔ 종류 매핑은 공개 문서가 없어 개수만 안다.
public struct CoreTopology: Equatable, Sendable {
    public var groups: [(name: String, count: Int)]
    public static func == (a: CoreTopology, b: CoreTopology) -> Bool {
        a.groups.count == b.groups.count && zip(a.groups, b.groups).allSatisfy { $0.name == $1.name && $0.count == $1.count }
    }
    public static func read() -> CoreTopology {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.nperflevels", &n, &size, nil, 0) == 0, n > 0 else { return CoreTopology(groups: []) }
        var groups: [(String, Int)] = []
        for i in 0..<Int(n) {
            var count: Int32 = 0
            var csize = MemoryLayout<Int32>.size
            guard sysctlbyname("hw.perflevel\(i).logicalcpu", &count, &csize, nil, 0) == 0 else { continue }
            var buf = [CChar](repeating: 0, count: 64)
            var bsize = buf.count
            let name = sysctlbyname("hw.perflevel\(i).name", &buf, &bsize, nil, 0) == 0 ? String(cString: buf) : "L\(i)"
            groups.append((name, Int(count)))
        }
        return CoreTopology(groups: groups)
    }
}
