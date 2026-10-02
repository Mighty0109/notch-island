import Foundation

/// 수집은 UI 밖 전용 큐에서 한 번만 한다. 접힘 2초 / 펼침 1초, 디스크는 30초.
public final class MetricsCollector {
    public static let collapsedInterval: TimeInterval = 2
    public static let expandedInterval: TimeInterval = 1
    public static let diskInterval: TimeInterval = 30

    /// 수집 큐에서 호출된다. `afterGap` 은 잠자기 복귀 등으로 시간축이 끊긴 직후의 첫 스냅샷.
    public var onSnapshot: ((_ snapshot: SystemSnapshot, _ afterGap: Bool) -> Void)?

    private let queue = DispatchQueue(label: "notchisland.collector", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var expanded = false

    private let cpu: CPUProvider
    private let thermal: ThermalProvider
    private let pressure: MemoryPressureProvider
    private let memUsage: MemoryUsageProvider
    private let battery: BatteryProvider
    private let disk: DiskProvider
    private let network: NetworkProvider
    private let processes: ProcessProvider

    private var lastDisk: Reading<DiskInfo>?
    private var lastDiskAt: Date?
    private var pendingGap = false

    public init(cpu: CPUProvider = CPUProvider(),
                thermal: ThermalProvider = ThermalProvider(),
                pressure: MemoryPressureProvider = MemoryPressureProvider(),
                memUsage: MemoryUsageProvider = MemoryUsageProvider(),
                battery: BatteryProvider = BatteryProvider(),
                disk: DiskProvider = DiskProvider(),
                network: NetworkProvider = NetworkProvider(),
                processes: ProcessProvider = ProcessProvider()) {
        self.cpu = cpu; self.thermal = thermal; self.pressure = pressure; self.memUsage = memUsage
        self.battery = battery; self.disk = disk; self.network = network; self.processes = processes
    }

    public func start() {
        pressure.startMonitoring()
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            schedule(first: .now())
            t.resume()
        }
    }

    public func stop() {
        pressure.stopMonitoring()
        queue.async { [self] in timer?.cancel(); timer = nil }
    }

    /// 펼침이면 1초 + 상위 프로세스 수집, 접힘이면 2초.
    public func setExpanded(_ value: Bool) {
        queue.async { [self] in
            guard expanded != value else { return }
            expanded = value
            if !value { processes.reset() }
            schedule(first: .now() + 0.05)
        }
    }

    /// 잠자기 복귀·화면 변경: 누적 카운터 기준점을 버린다(첫 샘플은 기준점으로만 사용).
    public func resetBaselines() {
        queue.async { [self] in
            cpu.reset(); network.reset(); processes.reset(); pendingGap = true
        }
    }

    private func schedule(first: DispatchTime) {
        let iv = expanded ? Self.expandedInterval : Self.collapsedInterval
        timer?.schedule(deadline: first, repeating: iv, leeway: .milliseconds(100))
    }

    /// 테스트·강제 호출용: 지금 한 번 수집(큐 위에서 동기 실행).
    public func collectNow(now: Date = Date()) -> SystemSnapshot {
        queue.sync { buildSnapshot(now: now) }
    }

    private func tick() {
        let gap = pendingGap
        pendingGap = false
        let snap = buildSnapshot(now: Date())
        onSnapshot?(snap, gap)
    }

    private func buildSnapshot(now: Date) -> SystemSnapshot {
        let c = cpu.sample(now: now)
        if lastDiskAt == nil || now.timeIntervalSince(lastDiskAt ?? now) >= Self.diskInterval {
            lastDisk = disk.sample(now: now); lastDiskAt = now
        }
        return SystemSnapshot(
            cpu: c.overall, cores: c.cores,
            thermal: thermal.sample(now: now),
            memory: pressure.sample(now: now),
            memoryUsage: memUsage.sample(now: now),
            battery: battery.sample(now: now),
            disk: lastDisk ?? .checking(unit: "bytes", at: now, source: "URLResourceValues"),
            network: network.sample(now: now),
            topProcesses: expanded ? processes.sample(now: now) : .checking(unit: "%", at: now, source: "libproc"),
            updatedAt: now)
    }
}
