import Foundation

/// 측정값의 상태. 실패를 0 으로 위장하지 않기 위해 값과 분리해서 들고 다닌다. (REVIEW 1-16)
public enum MetricStatus: Equatable, Sendable {
    case ok
    case checking                 // 확인 중 (아직 기준점이 없거나 첫 이벤트 전)
    case unsupported(String)      // 이 기기·배포판에서 못 읽음
    case failed(String)           // 일시 실패
}

/// 수집기가 내보내는 공통 형식: 값 + 단위 + 시각 + 상태 + 원천.
public struct Reading<Value: Equatable & Sendable>: Equatable, Sendable {
    public var value: Value?
    public var unit: String
    public var timestamp: Date
    public var status: MetricStatus
    public var source: String

    public init(value: Value?, unit: String, timestamp: Date, status: MetricStatus, source: String) {
        self.value = value
        self.unit = unit
        self.timestamp = timestamp
        self.status = status
        self.source = source
    }

    public static func ok(_ value: Value, unit: String, at: Date, source: String) -> Reading {
        Reading(value: value, unit: unit, timestamp: at, status: .ok, source: source)
    }

    public static func checking(unit: String, at: Date, source: String) -> Reading {
        Reading(value: nil, unit: unit, timestamp: at, status: .checking, source: source)
    }

    public static func unsupported(_ why: String, unit: String, at: Date, source: String) -> Reading {
        Reading(value: nil, unit: unit, timestamp: at, status: .unsupported(why), source: source)
    }

    public static func failed(_ why: String, unit: String, at: Date, source: String) -> Reading {
        Reading(value: nil, unit: unit, timestamp: at, status: .failed(why), source: source)
    }

    public var isOK: Bool { status == .ok && value != nil }
}

/// 공개 `ProcessInfo.ThermalState` 4단계. °C 가 아니다.
public enum ThermalLevel: Int, CaseIterable, Sendable, Comparable {
    case nominal = 0, fair, serious, critical
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .nominal: return "보통"
        case .fair: return "주의"
        case .serious: return "높음"
        case .critical: return "매우 높음"
        }
    }
}

/// `DispatchSource.MemoryPressureEvent` 3단계.
public enum MemoryPressureLevel: Int, CaseIterable, Sendable, Comparable {
    case normal = 0, warning, critical
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .normal: return "정상"
        case .warning: return "주의"
        case .critical: return "높음"
        }
    }
}

public struct CoreUsage: Equatable, Sendable {
    public var perCore: [Double]          // 0...1
    public init(perCore: [Double]) { self.perCore = perCore }
    public var average: Double { perCore.isEmpty ? 0 : perCore.reduce(0, +) / Double(perCore.count) }
}

public struct MemoryUsage: Equatable, Sendable {
    public var usedBytes: UInt64
    public var totalBytes: UInt64
    public init(usedBytes: UInt64, totalBytes: UInt64) { self.usedBytes = usedBytes; self.totalBytes = totalBytes }
}

public struct BatteryInfo: Equatable, Sendable {
    public var percent: Int
    public var isCharging: Bool
    public var onACPower: Bool
    public init(percent: Int, isCharging: Bool, onACPower: Bool) {
        self.percent = percent; self.isCharging = isCharging; self.onACPower = onACPower
    }
}

public struct DiskInfo: Equatable, Sendable {
    public var freeBytes: UInt64
    public var totalBytes: UInt64
    public var volumeName: String
    public init(freeBytes: UInt64, totalBytes: UInt64, volumeName: String) {
        self.freeBytes = freeBytes; self.totalBytes = totalBytes; self.volumeName = volumeName
    }
    public var freeGB: Double { Double(freeBytes) / 1_000_000_000 }
}

public struct NetworkRate: Equatable, Sendable {
    public var downBytesPerSec: Double
    public var upBytesPerSec: Double
    public init(downBytesPerSec: Double, upBytesPerSec: Double) {
        self.downBytesPerSec = downBytesPerSec; self.upBytesPerSec = upBytesPerSec
    }
}

public struct ProcessUsage: Equatable, Sendable {
    public var name: String
    public var cpuPercent: Double         // 코어 1개 = 100%
    public var residentBytes: UInt64
    public var count: Int                 // 같은 이름으로 합친 프로세스 수
    public init(name: String, cpuPercent: Double, residentBytes: UInt64, count: Int) {
        self.name = name; self.cpuPercent = cpuPercent; self.residentBytes = residentBytes; self.count = count
    }
}

/// 한 번의 수집 결과. 화면 수와 무관하게 한 번만 만들어 여러 곳에 전달한다.
public struct SystemSnapshot: Equatable, Sendable {
    public var cpu: Reading<Double>                 // 전체 CPU 용량 대비 0...100 (%)
    public var cores: Reading<CoreUsage>
    public var thermal: Reading<ThermalLevel>
    public var memory: Reading<MemoryPressureLevel>
    public var memoryUsage: Reading<MemoryUsage>
    public var battery: Reading<BatteryInfo>
    public var disk: Reading<DiskInfo>
    public var network: Reading<NetworkRate>
    public var topProcesses: Reading<[ProcessUsage]>
    public var updatedAt: Date

    public static func empty(at now: Date) -> SystemSnapshot {
        SystemSnapshot(
            cpu: .checking(unit: "%", at: now, source: "host_processor_info"),
            cores: .checking(unit: "%", at: now, source: "host_processor_info"),
            thermal: .checking(unit: "level", at: now, source: "ProcessInfo.thermalState"),
            memory: .checking(unit: "level", at: now, source: "DispatchSource.memoryPressure"),
            memoryUsage: .checking(unit: "bytes", at: now, source: "host_statistics64"),
            battery: .checking(unit: "%", at: now, source: "IOPowerSources"),
            disk: .checking(unit: "bytes", at: now, source: "URLResourceValues"),
            network: .checking(unit: "B/s", at: now, source: "getifaddrs"),
            topProcesses: .checking(unit: "%", at: now, source: "libproc"),
            updatedAt: now
        )
    }
}

/// 비공개 센서(°C·팬·전력) 모듈 자리. v0.1 은 구현 없음 — 스토어 타깃은 이 프로토콜의 구현을 링크하지 않는다.
public protocol PrivateSensorProvider {
    func readTemperatureCelsius() -> Reading<Double>
    func readFanRPM() -> Reading<Double>
    func readPowerWatts() -> Reading<Double>
}
