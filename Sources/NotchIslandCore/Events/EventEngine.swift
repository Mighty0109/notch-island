import Foundation

public enum AlertCause: String, CaseIterable, Sendable {
    case memory, thermal, charger
}

public struct AlertEvent: Equatable, Sendable {
    public var cause: AlertCause
    public var level: Int
    public var text: String
    public var priority: Int          // 클수록 먼저
    public var at: TimeInterval
    public init(cause: AlertCause, level: Int, text: String, priority: Int, at: TimeInterval) {
        self.cause = cause; self.level = level; self.text = text; self.priority = priority; self.at = at
    }
}

/// 같은 틱에 여러 건이 오면 가장 중요한 하나 + "추가 N건".
public struct AlertBundle: Equatable, Sendable {
    public var primary: AlertEvent
    public var extraCount: Int
    public init(primary: AlertEvent, extraCount: Int) { self.primary = primary; self.extraCount = extraCount }
}

/// 이벤트 판정 입력 — UI 와 수집기에서 독립. 기록을 그대로 다시 넣어 재생할 수 있다.
public struct Observation: Equatable, Sendable {
    public var time: TimeInterval          // 단조 초
    public var memory: Int?                // 0 정상 · 1 주의 · 2 높음. nil = 아직 모름
    public var thermal: Int?               // 0 보통 · 1 주의 · 2 높음 · 3 매우 높음
    public var onAC: Bool?
    public var chargePercent: Int?
    public var topApp: String?             // 관찰 사실 문구 (원인 단정 아님)
    public init(time: TimeInterval, memory: Int? = nil, thermal: Int? = nil, onAC: Bool? = nil, chargePercent: Int? = nil, topApp: String? = nil) {
        self.time = time; self.memory = memory; self.thermal = thermal
        self.onAC = onAC; self.chargePercent = chargePercent; self.topApp = topApp
    }
}

public struct EngineConfig: Equatable, Sendable {
    public var enterHold: TimeInterval = 5          // 경고 진입은 이만큼 지속돼야 인정
    public var exitHold: TimeInterval = 15          // 회복은 이만큼 지속돼야 인정
    public var suppress: TimeInterval = 300         // 같은 원인 재알림 대기
    public var memoryAlertMinLevel = 1
    public var thermalAlertMinLevel = 2             // fair(주의)는 흔해서 알림 기준 아님
    public var memoryImmediateLevel = 2             // 이 단계 이상은 지연 없이 즉시
    public var thermalImmediateLevel = 2
    public init() {}
}

/// 진입 지연 · 회복 지연(히스테리시스)이 있는 단계 추적기.
struct LevelTracker {
    var effective = 0
    private var upSince: TimeInterval?
    private var downSince: TimeInterval?
    let enterHold: TimeInterval, exitHold: TimeInterval, immediate: Int

    init(enterHold: TimeInterval, exitHold: TimeInterval, immediate: Int) {
        self.enterHold = enterHold; self.exitHold = exitHold; self.immediate = immediate
    }

    mutating func clearPending() { upSince = nil; downSince = nil }

    /// - Returns: 이번 입력으로 유효 단계가 올라갔으면 true
    mutating func ingest(raw: Int?, t: TimeInterval) -> Bool {
        guard let raw else { return false }
        if raw > effective {
            downSince = nil
            if raw >= immediate { effective = raw; upSince = nil; return true }
            if upSince == nil { upSince = t }
            if t - (upSince ?? t) >= enterHold { effective = raw; upSince = nil; return true }
            return false
        }
        if raw < effective {
            upSince = nil
            if downSince == nil { downSince = t }
            if t - (downSince ?? t) >= exitHold { effective = raw; downSince = nil }
            return false
        }
        upSince = nil; downSince = nil
        return false
    }
}

public struct EventEngine {
    public private(set) var config: EngineConfig
    private var memory: LevelTracker
    private var thermal: LevelTracker
    private var lastAC: Bool?
    private var lastAlert: [AlertCause: (time: TimeInterval, level: Int)] = [:]

    public var effectiveMemoryLevel: Int { memory.effective }
    public var effectiveThermalLevel: Int { thermal.effective }

    public init(config: EngineConfig = EngineConfig()) {
        self.config = config
        memory = LevelTracker(enterHold: config.enterHold, exitHold: config.exitHold, immediate: config.memoryImmediateLevel)
        thermal = LevelTracker(enterHold: config.enterHold, exitHold: config.exitHold, immediate: config.thermalImmediateLevel)
    }

    /// 잠자기 복귀·화면 변경 뒤: 진행 중이던 지연 타이머와 충전기 직전값을 버려 오래된 사건을 재생하지 않는다.
    public mutating func reset() {
        memory.clearPending(); thermal.clearPending(); lastAC = nil
    }

    public mutating func ingest(_ o: Observation) -> AlertBundle? {
        var found: [AlertEvent] = []

        if memory.ingest(raw: o.memory, t: o.time), memory.effective >= config.memoryAlertMinLevel,
           let e = admit(.memory, level: memory.effective, o: o) { found.append(e) }
        if thermal.ingest(raw: o.thermal, t: o.time), thermal.effective >= config.thermalAlertMinLevel,
           let e = admit(.thermal, level: thermal.effective, o: o) { found.append(e) }

        if let ac = o.onAC {
            if let was = lastAC, was == false, ac == true, let e = admit(.charger, level: 0, o: o) { found.append(e) }
            lastAC = ac
        }

        guard !found.isEmpty else { return nil }
        let order: [AlertCause] = [.memory, .thermal, .charger]      // 우선순위가 같을 때의 결정적 순서
        found.sort { a, b in
            a.priority != b.priority ? a.priority > b.priority : (order.firstIndex(of: a.cause) ?? 0) < (order.firstIndex(of: b.cause) ?? 0)
        }
        return AlertBundle(primary: found[0], extraCount: found.count - 1)
    }

    /// 같은 원인은 5분 안에 같거나 낮은 단계로 다시 알리지 않는다. 더 높은 단계로 악화하면 즉시 통과.
    private mutating func admit(_ cause: AlertCause, level: Int, o: Observation) -> AlertEvent? {
        if let last = lastAlert[cause], o.time - last.time < config.suppress, level <= last.level { return nil }
        lastAlert[cause] = (o.time, level)
        return AlertEvent(cause: cause, level: level, text: Self.text(cause, level: level, o: o),
                          priority: Self.priority(cause, level: level), at: o.time)
    }

    static func priority(_ cause: AlertCause, level: Int) -> Int {
        switch cause {
        case .memory, .thermal: return (level >= 2 ? 30 : 20) + level
        case .charger: return 10
        }
    }

    static func text(_ cause: AlertCause, level: Int, o: Observation) -> String {
        switch cause {
        case .memory:
            let base = "메모리 압박 " + (level >= 2 ? "높음" : "주의")
            return o.topApp.map { base + " · 관찰된 사용 상위: " + $0 } ?? base
        case .thermal:
            let labels = ["보통", "주의", "높음", "매우 높음"]
            let base = "열 상태 " + labels[min(max(level, 0), 3)]
            return o.topApp.map { base + " · 관찰된 사용 상위: " + $0 } ?? base
        case .charger:
            return o.chargePercent.map { "충전기 연결 · \($0)%" } ?? "충전기 연결"
        }
    }
}
