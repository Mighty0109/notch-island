import Foundation

public protocol ThermalSource {
    func currentState() -> ProcessInfo.ThermalState
}

public struct SystemThermalSource: ThermalSource {
    public init() {}
    public func currentState() -> ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }
}

/// 공개 `ProcessInfo.thermalState` 4단계. °C·스로틀링 시작 시각을 주장하지 않는다.
public final class ThermalProvider {
    private let source: ThermalSource
    public init(source: ThermalSource = SystemThermalSource()) { self.source = source }

    public static func level(from state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    public func sample(now: Date) -> Reading<ThermalLevel> {
        .ok(Self.level(from: source.currentState()), unit: "level", at: now, source: "ProcessInfo.thermalState")
    }
}
