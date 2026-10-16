import Foundation
import NotchIslandCore

/// SMC 온도·팬 센서를 집계한다. **읽기 전용**, 키 열거는 첫 샘플에서 한 번만 한다(이후엔 필요한 키만 읽는다).
/// 키의 의미는 공식 문서가 없고 부하 실험으로 추정한 것이라 개별 키가 아니라 평균·최대로만 쓴다:
/// CPU = `Tp*` · GPU = `Tg*` · 배터리 = `TB0T` · 팬 = `F0Ac`…`F(FNum-1)Ac`.
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
        var isEmpty: Bool { cpuKeys.isEmpty && gpuKeys.isEmpty && batteryKey == nil && fanKeys.isEmpty }
    }

    private enum State { case notStarted, unsupported(String), ready(SMCSource, Plan) }

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
        case .unsupported(let why):
            return .unsupported(why, unit: "°C", at: now, source: Self.source)
        case .ready(let smc, let plan):
            let v = Self.aggregate(plan: plan, smc: smc)
            if v.cpuAverage == nil, v.gpuAverage == nil, v.battery == nil, v.fanRPMs.isEmpty {
                return .failed("유효한 센서 값 없음", unit: "°C", at: now, source: Self.source)
            }
            return .ok(v, unit: "°C", at: now, source: Self.source)
        }
    }

    // MARK: 시작 — 연결 + 키 열거(1회)

    private func start() -> State {
        guard let smc = makeSource() else { return .unsupported("AppleSMC 를 열 수 없음") }
        guard let total = smc.keyCount(), total > 0 else { return .unsupported("SMC 키 목록을 읽을 수 없음") }
        var cpu: [String] = [], gpu: [String] = [], battery: String?
        for i in 0..<total {
            guard let k = smc.key(at: i) else { break }
            if k.hasPrefix("Tp") { cpu.append(k) } else if k.hasPrefix("Tg") { gpu.append(k) } else if k == "TB0T" { battery = k }
        }
        var fanKeys: [String] = []
        if let n = smc.read("FNum").flatMap(SMCDecode.number), n >= 1 {
            fanKeys = (0..<Int(min(n, 8))).map { "F\($0)Ac" }
        }
        let plan = Plan(cpuKeys: cpu, gpuKeys: gpu, batteryKey: battery, fanKeys: fanKeys)
        return plan.isEmpty ? .unsupported("이 기기에서 쓸 수 있는 SMC 센서 키가 없음") : .ready(smc, plan)
    }

    // MARK: 집계

    private static func aggregate(plan: Plan, smc: SMCSource) -> SensorValues {
        func temps(_ keys: [String]) -> [Double] {
            keys.compactMap { smc.read($0).flatMap(SMCDecode.number) }.filter { validTemperature.contains($0) }
        }
        func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
        let cpu = temps(plan.cpuKeys)
        let fans = plan.fanKeys.compactMap { smc.read($0).flatMap(SMCDecode.number) }.filter { validRPM.contains($0) }
        return SensorValues(cpuAverage: mean(cpu), cpuMax: cpu.max(), gpuAverage: mean(temps(plan.gpuKeys)),
                            battery: plan.batteryKey.flatMap { temps([$0]).first }, fanRPMs: fans)
    }
}
