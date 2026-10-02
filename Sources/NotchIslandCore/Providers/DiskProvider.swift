import Foundation

public protocol DiskSource {
    func read() -> DiskInfo?
}

/// 시작 볼륨의 남은 공간. APFS 의 "중요 용도 사용 가능 용량"(정리 가능 공간 포함, Finder 와 같은 기준)을 쓴다.
public struct StartupVolumeDiskSource: DiskSource {
    public init() {}
    public func read() -> DiskInfo? {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeNameKey]
        guard let v = try? url.resourceValues(forKeys: keys),
              let free = v.volumeAvailableCapacityForImportantUsage,
              let total = v.volumeTotalCapacity, total > 0 else { return nil }
        return DiskInfo(freeBytes: UInt64(max(0, free)), totalBytes: UInt64(total), volumeName: v.volumeName ?? "/")
    }
}

public final class DiskProvider {
    private let source: DiskSource
    public init(source: DiskSource = StartupVolumeDiskSource()) { self.source = source }
    public func sample(now: Date) -> Reading<DiskInfo> {
        guard let d = source.read() else { return .failed("읽기 실패", unit: "bytes", at: now, source: "URLResourceValues") }
        return .ok(d, unit: "bytes", at: now, source: "URLResourceValues")
    }
}
