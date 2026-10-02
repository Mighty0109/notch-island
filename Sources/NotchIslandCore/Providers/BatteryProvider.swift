import Foundation
import IOKit.ps

public enum BatteryParser {
    /// IOPSGetPowerSourceDescription 사전 → BatteryInfo. 내장 배터리가 아니면 nil.
    public static func parse(_ d: [String: Any]) -> BatteryInfo? {
        guard (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { return nil }
        guard let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { return nil }
        let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
        let state = d[kIOPSPowerSourceStateKey] as? String
        let onAC = state == kIOPSACPowerValue
        return BatteryInfo(percent: Swift.min(100, Swift.max(0, cur * 100 / max)), isCharging: charging, onACPower: onAC)
    }
}

public protocol BatterySource {
    /// nil = 내장 배터리 없음(데스크톱 Mac) 또는 읽기 실패. 구분은 `hasBattery`.
    func read() -> BatteryInfo?
}

public struct IOPSBatterySource: BatterySource {
    public init() {}
    public func read() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            if let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
               let info = BatteryParser.parse(desc) { return info }
        }
        return nil
    }
}

public final class BatteryProvider {
    private let source: BatterySource
    public init(source: BatterySource = IOPSBatterySource()) { self.source = source }
    public func sample(now: Date) -> Reading<BatteryInfo> {
        if let b = source.read() { return .ok(b, unit: "%", at: now, source: "IOPowerSources") }
        return .unsupported("내장 배터리 없음", unit: "%", at: now, source: "IOPowerSources")
    }
}
