import Foundation

/// 1분(60칸) 고정 길이 기록. nil = 측정 못 한 구간(그래프에 빈칸으로 그린다).
public struct SampleHistory<T: Equatable & Sendable>: Equatable, Sendable {
    public private(set) var values: [T?] = []
    public let capacity: Int
    public init(capacity: Int = 60) { self.capacity = capacity }

    public mutating func append(_ v: T?) {
        values.append(v)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
    public mutating func removeAll() { values.removeAll() }
}

public struct MetricsHistory: Equatable, Sendable {
    public var cpu = SampleHistory<Double>()         // 0...100
    public var thermal = SampleHistory<Int>()        // 0...3
    public var memory = SampleHistory<Int>()         // 0...2
    public init() {}

    public mutating func record(_ s: SystemSnapshot) {
        cpu.append(s.cpu.value)
        thermal.append(s.thermal.value?.rawValue)
        memory.append(s.memory.value?.rawValue)
    }
    /// 잠자기 복귀 등으로 시간축이 끊기면 사이를 빈칸으로 메운다(가짜 연속선 금지).
    public mutating func markGap() {
        cpu.append(nil); thermal.append(nil); memory.append(nil)
    }
}
