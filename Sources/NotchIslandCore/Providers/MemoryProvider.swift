import Foundation
import Darwin

public protocol MemoryPressureProbe {
    func read() -> MemoryPressureLevel?
}

/// 시작 직후엔 압박 이벤트가 안 오므로 한 번 읽어 기준점으로 삼는 읽기 전용 sysctl (1 정상 · 2 주의 · 4 높음).
public struct SysctlMemoryPressureProbe: MemoryPressureProbe {
    public init() {}
    public func read() -> MemoryPressureLevel? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &v, &size, nil, 0) == 0 else { return nil }
        switch v {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return nil
        }
    }
}

/// 메모리 압박 수집기.
/// - 첫 샘플은 이벤트가 없으면 무조건 "확인 중" (없다고 정상으로 확정하지 않는다).
/// - 이후 이벤트가 오기 전까지는 probe 로 읽은 기준점을 쓰고, 이벤트가 오면 이벤트가 이긴다.
public final class MemoryPressureProvider {
    private let lock = NSLock()
    private let probe: MemoryPressureProbe?
    private var latest: MemoryPressureLevel?
    private var fromEvent = false
    private var samples = 0
    private var dispatchSource: DispatchSourceMemoryPressure?

    public init(probe: MemoryPressureProbe? = SysctlMemoryPressureProbe()) { self.probe = probe }

    /// DispatchSource 구독 시작. 이벤트는 전용 큐에서 오고 lock 으로 보호한다.
    public func startMonitoring(queue: DispatchQueue = DispatchQueue(label: "notchisland.memory-pressure")) {
        guard dispatchSource == nil else { return }
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            self.ingest(event: src.data)
        }
        src.resume()
        dispatchSource = src
    }

    public func stopMonitoring() {
        dispatchSource?.cancel()
        dispatchSource = nil
    }

    public func ingest(event: DispatchSource.MemoryPressureEvent) {
        let level: MemoryPressureLevel
        if event.contains(.critical) { level = .critical }
        else if event.contains(.warning) { level = .warning }
        else if event.contains(.normal) { level = .normal }
        else { return }
        lock.lock(); defer { lock.unlock() }
        latest = level
        fromEvent = true
    }

    public func sample(now: Date) -> Reading<MemoryPressureLevel> {
        lock.lock(); defer { lock.unlock() }
        samples += 1
        let unit = "level"
        if let level = latest, fromEvent {
            return .ok(level, unit: unit, at: now, source: "DispatchSource.memoryPressure")
        }
        if samples == 1 { return .checking(unit: unit, at: now, source: "DispatchSource.memoryPressure") }
        if latest == nil, let p = probe?.read() { latest = p }
        if let level = latest {
            return .ok(level, unit: unit, at: now, source: "sysctl 초기값 (이벤트 도착 전)")
        }
        return .checking(unit: unit, at: now, source: "DispatchSource.memoryPressure")
    }
}

public protocol MemoryUsageSource {
    func read() -> MemoryUsage?
}

/// "사용된 메모리" 계산 — 활성 상태 보기의 정의: 앱 메모리(internal − purgeable) + 와이어드 + 압축.
/// 파일 백업(external, 캐시) 페이지와 purgeable 은 넣지 않는다 (맥은 캐시로 메모리를 채우므로 넣으면 늘 높다).
public enum MemoryMath {
    public static func usedBytes(from s: vm_statistics64, pageSize: UInt64) -> UInt64 {
        let app = UInt64(s.internal_page_count) &- UInt64(s.purgeable_count)
        return (app + UInt64(s.wire_count) + UInt64(s.compressor_page_count)) * pageSize
    }

    /// 사용 비율 0...100 (%) — 물리 메모리 대비
    public static func percent(_ u: MemoryUsage) -> Double {
        guard u.totalBytes > 0 else { return 0 }
        return min(100, max(0, Double(u.usedBytes) / Double(u.totalBytes) * 100))
    }

    public static let bytesPerGB: Double = 1_073_741_824      // 활성 상태 보기도 GB 로 1024³ 을 쓴다
}

public struct HostMemoryUsageSource: MemoryUsageSource {
    public init() {}
    public func read() -> MemoryUsage? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return MemoryUsage(usedBytes: MemoryMath.usedBytes(from: stats, pageSize: UInt64(vm_kernel_page_size)),
                           totalBytes: ProcessInfo.processInfo.physicalMemory)
    }
}

public final class MemoryUsageProvider {
    private let source: MemoryUsageSource
    public init(source: MemoryUsageSource = HostMemoryUsageSource()) { self.source = source }
    public func sample(now: Date) -> Reading<MemoryUsage> {
        guard let u = source.read() else { return .failed("읽기 실패", unit: "bytes", at: now, source: "host_statistics64") }
        return .ok(u, unit: "bytes", at: now, source: "host_statistics64")
    }
}
