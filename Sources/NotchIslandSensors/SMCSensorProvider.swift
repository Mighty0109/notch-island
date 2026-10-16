import Foundation
import NotchIslandCore

/// SMC 온도·팬 센서를 집계한다. **읽기 전용**, 키 열거가 끝까지 성공하면 한 번만 캐시한다(실패하면 다음 샘플에서 재시도).
/// 키의 의미는 공식 문서가 없고 부하 실험으로 추정한 것이라 개별 키가 아니라 평균·최대로만 쓴다:
/// CPU = `Tp*` · GPU = `Tg*` · 배터리 = `TB0T` · 팬 = `F{i}Ac` / `F{i}Mx`.
/// 수집 큐 한 곳에서만 부른다(스레드 안전하지 않다).
public final class SMCSensorProvider: PrivateSensorProvider {
    public static let source = "SMC (비공개 · 키 의미 추정)"
    /// 이 범위 밖의 온도(0 이하 · 130 초과)와 RPM(음수 · 30000 초과)은 센서 오류로 보고 버린다.
    static let validTemperature: ClosedRange<Double> = 0.000_001...130
    static let validRPM: ClosedRange<Double> = 0...30_000

    private struct Plan {
        var cpuKeys: [String]
        var gpuKeys: [String]
        var batteryKey: String?
        var fanKeys: [String]
        var fanMaxRPMs: [Double?]       // 시작 때 한 번만 읽는 하드웨어 상수
        var isEmpty: Bool { cpuKeys.isEmpty && gpuKeys.isEmpty && batteryKey == nil && fanKeys.isEmpty }
    }

    private enum State { case notStarted, failed(String), unsupported(String), ready(SMCSource, Plan) }

    private let makeSource: () -> SMCSource?
    private var state: State = .notStarted

    /// `makeSource` 는 첫 샘플 때 처음 불린다(접힌 동안 SMC 를 열지 않는다).
    public init(makeSource: @escaping () -> SMCSource? = { AppleSMCConnection() }) {
        self.makeSource = makeSource
    }

    public func sample(now: Date) -> Reading<SensorValues> {
        if case .notStarted = state { state = start() }
        switch state {
        case .notStarted:
            return .checking(unit: "°C", at: now, source: Self.source)
        case .failed(let why):
            state = .notStarted
            return .failed(why, unit: "°C", at: now, source: Self.source)
        case .unsupported(let why):
            return .unsupported(why, unit: "°C", at: now, source: Self.source)
        case .ready(let smc, let plan):
            let v = Self.aggregate(plan: plan, smc: smc)
            if v.cpuAverage == nil, v.gpuAverage == nil, v.battery == nil, v.fanRPMs.allSatisfy({ $0 == nil }) {
                return .failed("유효한 센서 값 없음", unit: "°C", at: now, source: Self.source)
            }
            return .ok(v, unit: "°C", at: now, source: Self.source)
        }
    }

    // MARK: 시작 — 연결 + 키 열거(성공한 계획만 1회 캐시)

    private func start() -> State {
        guard let smc = makeSource() else { return .unsupported("AppleSMC 를 열 수 없음") }
        guard let total = smc.keyCount(), total > 0 else { return .unsupported("SMC 키 목록을 읽을 수 없음") }
        var cpu: [String] = [], gpu: [String] = [], battery: String?
        for i in 0..<total {
            guard let k = smc.key(at: i) else { return .failed("SMC 키 열거 실패 (index \(i))") }
            if k.hasPrefix("Tp") { cpu.append(k) } else if k.hasPrefix("Tg") { gpu.append(k) } else if k == "TB0T" { battery = k }
        }
        var fanKeys: [String] = []
        if let n = smc.read("FNum").flatMap(SMCDecode.number), n >= 1 {
            fanKeys = (0..<Int(min(n, 8))).map { "F\($0)Ac" }
        }
        let maxima = fanKeys.indices.map { i -> Double? in
            guard let rpm = smc.read("F\(i)Mx").flatMap(SMCDecode.number), rpm > 0, Self.validRPM.contains(rpm) else { return nil }
            return rpm
        }
        let plan = Plan(cpuKeys: cpu, gpuKeys: gpu, batteryKey: battery, fanKeys: fanKeys, fanMaxRPMs: maxima)
        return plan.isEmpty ? .unsupported("이 기기에서 쓸 수 있는 SMC 센서 키가 없음") : .ready(smc, plan)
    }

    // MARK: 집계

    private static func aggregate(plan: Plan, smc: SMCSource) -> SensorValues {
        func temps(_ keys: [String]) -> [Double] {
            keys.compactMap { smc.read($0).flatMap(SMCDecode.number) }.filter { validTemperature.contains($0) }
        }
        func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
        let cpu = temps(plan.cpuKeys)
        // 못 읽은 팬도 자리를 남겨 실제 팬 번호와 최고 RPM 의 짝을 유지한다.
        let fans = plan.fanKeys.map { key -> Double? in
            guard let rpm = smc.read(key).flatMap(SMCDecode.number), validRPM.contains(rpm) else { return nil }
            return rpm
        }
        return SensorValues(cpuAverage: mean(cpu), cpuMax: cpu.max(), gpuAverage: mean(temps(plan.gpuKeys)),
                            battery: plan.batteryKey.flatMap { temps([$0]).first },
                            fanRPMs: fans, fanMaxRPMs: plan.fanMaxRPMs)
    }
}
