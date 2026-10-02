import SwiftUI
import AppKit
import Combine
import NotchIslandCore

/// 선언 순서 = 카드 3칸 순서 (CPU · 메모리 · 열)
enum SlotKind: CaseIterable { case cpu, memory, thermal }

enum DropStage: Equatable { case hidden, falling, pill, retract }

struct HeadlineEvent: Equatable {
    var text: String
    var level: Int
    var cause: AlertCause
    var extra: Int
}

struct JobInfo: Equatable {
    var label: String
    var short: String
    var percent: Int
}


/// 슬롯(접힘 3칸 / 펼침 머리줄)에 그릴 값을 모양·글자·단계로 정리한 것
struct SlotDisplay: Equatable {
    var glyph: String       // 단계 모양 (CPU 는 없음)
    var value: String       // CPU: "9%" / 열·메모리: 단계 단어(툴팁·카드·펼침 단어용)
    var pct: String         // 메모리 사용 % (활성 상태 보기 "사용된 메모리" ÷ 물리 메모리)
    var level: Int          // 0 정상 · 1 주의 · 2 높음 — 색에 쓴다
    var spoken: String      // VoiceOver 라벨·호버 툴팁 (단어는 여기에만)
    var checking: Bool
}

/// 상태 머신·수집·이벤트 판정을 한데 엮는 화면 쪽 모델. 계산 규칙은 Core 에 있고 여기는 연결만 한다.
@MainActor
final class IslandModel: ObservableObject {
    let settings: SettingsStore
    let machine: IslandStateMachine
    private let collector = MetricsCollector()
    private var engine = EventEngine()
    private var cancellables: Set<AnyCancellable> = []

    @Published private(set) var phase: IslandPhase = .collapsed { didSet { if phase != oldValue { rebuildLayout() } } }
    @Published private(set) var snapshot = SystemSnapshot.empty(at: Date())
    @Published private(set) var history = MetricsHistory()
    @Published private(set) var event: HeadlineEvent?
    @Published private(set) var alertText = "" { didSet { if alertText != oldValue { pillTextWidth = Self.measureText(alertText); pillWidth = Self.pillWidth(forText: pillTextWidth) } } }
    /// 알림 글자 폭(◆ 모양 + 간격 포함) — 타이핑 중에도 글자가 제자리에 있도록 라벨을 이 폭 안에서 왼쪽 정렬한다
    private(set) var pillTextWidth: CGFloat = 200
    /// 알약 폭 — 글자가 바뀔 때만 계산한다(마우스 이벤트마다 레이아웃을 만들 때 글자 측정이 돌지 않게)
    private(set) var pillWidth: CGFloat = 240 { didSet { if pillWidth != oldValue { rebuildLayout() } } }
    @Published private(set) var drop: DropStage = .hidden { didSet { if drop != oldValue { dropStartedAt = Date() } } }
    private(set) var dropStartedAt = Date()
    private(set) var openedAt = Date()
    @Published private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @Published private(set) var job: JobInfo?
    @Published private(set) var recovered: Set<AlertCause> = []
    @Published private(set) var memorySide: MemorySlotFlow.Side = .right
    /// 날개 폭(좌우 같은 값). 접힘은 촘촘, 펼침은 단어가 들어가게 — 글자 폭을 재서 계산하고 바뀔 때만 갱신(마우스 이벤트마다 재지 않게)
    private(set) var wings: (collapsed: IslandLayout.Wings, open: IslandLayout.Wings) = (IslandLayout.Wings(left: 80, right: 147), IslandLayout.Wings(left: 100, right: 270)) {
        didSet { if wings.collapsed != oldValue.collapsed || wings.open != oldValue.open { rebuildLayout() } }
    }
    private var wordWidthCache: [String: CGFloat] = [:]
    private var flow = MemorySlotFlow()
    private var debugLongJob = false
    private var suppressJob = false          // 검증용(--no-job): 실제 충전 중이어도 진행 링을 안 띄운다
    @Published private(set) var geometry: NotchGeometry? { didSet { if geometry != oldValue { rebuildLayout() } } }
    @Published private(set) var cardHeight: CGFloat = 426 { didSet { if cardHeight != oldValue { rebuildLayout() } } }     // 안 4 카드 고정 높이(섹션 자리 예약 — 값이 바뀌어도 안 변한다). 첫 펼침에서 튀지 않게 실제 값에 가깝게(측정되면 갱신)
    /// 카드 뷰는 접힌 동안 만들지 않는다(보이지 않아도 매 틱 다시 그려져 CPU 를 먹는다 — 실측). 닫히는 애니메이션이 끝난 뒤 내린다.
    @Published private(set) var cardMounted = false
    private var unmountToken = 0
    @Published private(set) var lastCores: [Double] = []
    /// 카드 로그 스트림(최근 3줄). 펼쳐 있는 동안 수집 틱마다 한 줄, 알림이 나면 경고 한 줄.
    @Published private(set) var statusLog = StatusLog()
    private var logStep = 0
    private var logTick = 0
    let topology = CoreTopology.read()

    // 디버그 강제값 (디버그 메뉴) — 같은 판정 경로를 타도록 스냅샷에 덮어쓴다
    private var forcedMemory: Int?
    private var forcedThermal: Int?
    private var forcedCharging = false
    private var forceTimers: [AlertCause: DispatchWorkItem] = [:]
    private var eventTimer: DispatchWorkItem?
    private var recoverTimers: [AlertCause: DispatchWorkItem] = [:]
    private var dropToken = 0
    private var prevDisplayLevel: [AlertCause: Int] = [:]
    private var userHidden = false
    private var systemHidden = false
    private var lastTopProcesses: [ProcessUsage] = []
    private var forceReduceMotion = false
    private var lastRaw = SystemSnapshot.empty(at: Date())     // 디버그 덮어쓰기 전의 실측 스냅샷

    /// 레이아웃·입력 판정이 바뀌면 컨트롤러가 알아야 한다(패널 입력 통과 여부)
    var onLayoutChange: (() -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
        self.machine = IslandStateMachine(scheduler: DispatchScheduler())
        machine.hoverEnabled = settings.hoverExpand
        machine.onPhaseChange = { [weak self] from, to in self?.phaseChanged(from: from, to: to) }
        if Self.traceOn { machine.trace = { [weak self] msg in self?.trace(msg) } }       // 꺼져 있으면 nil → 상태 머신이 문자열을 만들지 않는다

        settings.$hoverExpand.sink { [weak self] v in self?.machine.hoverEnabled = v }.store(in: &cancellables)

        collector.onSnapshot = { [weak self] snap, gap in
            DispatchQueue.main.async { self?.ingest(snap, afterGap: gap) }
        }
        NotificationCenter.default.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshReduceMotion() }
        }
        updateGeometry()
    }

    private func refreshReduceMotion() {
        reduceMotion = forceReduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 검증용: 시스템 설정과 무관하게 움직임 줄이기를 강제한다 (--reduce-motion)
    func debugForceReduceMotion() { forceReduceMotion = true; refreshReduceMotion() }

    func start() { collector.start() }
    func stop() { collector.stop() }

    // MARK: 지오메트리 · 레이아웃

    func updateGeometry() {
        geometry = NotchGeometry.current()
        onLayoutChange?()
    }

    /// 현재 레이아웃. 입력(단계·지오메트리·날개·카드 높이·알약 폭)이 바뀔 때만 다시 만든다 — 마우스 이벤트마다 읽히는 값이라,
    /// 예전처럼 `@Published` 다섯 개를 매번 읽어 조립하면 섬 위 이동 프로파일에서 메인 스레드의 ~20%(66/975ms, 실커서 샘플)를 먹었다.
    private(set) var layout = IslandLayout(phase: .collapsed, notchWidth: 200, notchHeight: 38)

    private func rebuildLayout() {
        let g = geometry
        // 섬 폭이 짝수 pt 여야 가운데 정렬이 반 픽셀에 안 걸려 글자가 선명하다
        layout = IslandLayout(phase: phase, notchWidth: ceil((g?.notchWidth ?? 200) / 2) * 2, notchHeight: g?.notchHeight ?? 38,
                              wingsCollapsed: wings.collapsed, wingsOpen: wings.open, cardHeight: cardHeight, pillWidth: pillWidth)
    }

    private static func measureText(_ text: String) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width) + 21      // + "◆ " 모양과 간격
    }

    private static func pillWidth(forText w: CGFloat) -> CGFloat {
        min(IslandLayout.panelWidth - 40, max(240, w + 43))       // 이전 식(글자 + 64)과 같은 폭: 모양 몫(21)을 글자 폭으로 옮겼다
    }

    /// 펼침만 살짝 튕긴다(시작=접힘 크기 미만으로는 못 내려감). 접힘·그 밖의 크기 변화는 임계 감쇠라 오버슈트가 없다 —
    /// 접힘 크기 아래로 내려가면 하드웨어 노치가 드러난다. 뷰는 추가로 프레임마다 접힘 크기 미만을 잘라낸다(`IslandFrame`).
    func animation(opening: Bool) -> Animation? {
        if reduceMotion { return nil }
        return opening ? .spring(response: IslandMotion.openResponse, dampingFraction: IslandMotion.openDamping)
                       : .spring(response: IslandMotion.closeResponse, dampingFraction: IslandMotion.closeDamping)
    }

    /// `delay`: 닫힐 때 카드가 먼저 사라질 시간(`IslandMotion.closeDelay`) — 외곽이 줄기 시작하는 시점만 늦춘다
    func setAnimated(opening: Bool = false, delay: Double = 0, _ body: () -> Void) {
        if let a = animation(opening: opening) { withAnimation(delay > 0 ? a.delay(delay) : a, body) } else { body() }
    }

    /// 카드 높이가 바뀌면(알림 줄·진행 줄 등) 섬 크기를 같은 계열의 애니메이션으로 — 한쪽만 튀지 않게
    func updateCardHeight(_ h: CGFloat) {
        guard h > 100, abs(h - cardHeight) > 0.5 else { return }
        if phase.isOpen { setAnimated { self.cardHeight = h } } else { cardHeight = h }
        onLayoutChange?()
    }

    /// `NOTCH_ISLAND_TRACE=1` 로 켜는 상태 추적 로그(포인터 구역·단계 전이) — 실기에서 이탈 누락 같은 문제를 보려고
    func trace(_ msg: @autoclosure () -> String) {
        guard IslandModel.traceOn else { return }          // 꺼져 있으면 문자열도 만들지 않는다(마우스 이벤트 경로)
        print(String(format: "TRACE %.3f %@", ProcessInfo.processInfo.systemUptime, msg())); fflush(stdout)
    }
    static let traceOn = ProcessInfo.processInfo.environment["NOTCH_ISLAND_TRACE"] != nil

    // MARK: 포인터 · 조작 (패널 컨트롤러가 호출)

    func pointerMoved(_ zone: PointerZone) { machine.pointerMoved(zone) }
    func click(_ zone: PointerZone) { machine.click(zone) }
    func close() { machine.close() }

    func setUserHidden(_ v: Bool) { userHidden = v; applyHidden() }
    func setSystemHidden(_ v: Bool) { systemHidden = v; applyHidden() }
    var isUserHidden: Bool { userHidden }
    private func applyHidden() { machine.setHidden(userHidden || systemHidden) }

    private func phaseChanged(from: IslandPhase, to: IslandPhase) {
        if to.isOpen {
            unmountToken += 1
            cardMounted = true
            if !from.isOpen {
                openedAt = Date()
                seedLog()
            }
        } else if from.isOpen {
            unmountToken += 1
            let t = unmountToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + IslandMotion.closeDelay) { [weak self] in
                guard let self, self.unmountToken == t, !self.phase.isOpen else { return }
                self.cardMounted = false
            }
        }
        setAnimated(opening: to.isOpen, delay: from.isOpen && !to.isOpen ? IslandMotion.closeDelay : 0) { self.phase = to }
        refreshMemorySide()          // 접힘/펼침 폭이 다르니 균형 판정도 다시
        trace("phase \(from) → \(to)")
        collector.setExpanded(to.isOpen)
        if from == .alert { endDrop(to: to) }
        onLayoutChange?()
    }

    // MARK: 수집 → 기록 → 판정

    func systemDidWake() {
        collector.resetBaselines()
        engine.reset()
    }

    private func ingest(_ raw: SystemSnapshot, afterGap: Bool) {
        lastRaw = raw
        var s = raw
        let now = raw.updatedAt
        if let f = forcedMemory { s.memory = .ok(MemoryPressureLevel(rawValue: f) ?? .critical, unit: "level", at: now, source: "디버그 강제값") }
        if let f = forcedThermal { s.thermal = .ok(ThermalLevel(rawValue: f) ?? .serious, unit: "level", at: now, source: "디버그 강제값") }
        if afterGap { history.markGap() }
        history.record(s)
        snapshot = s
        if phase.isOpen { appendInfoLog(s) }
        if let c = s.cores.value?.perCore { lastCores = c }
        if let p = s.topProcesses.value, !p.isEmpty { lastTopProcesses = p }
        updateJob(s)
        refreshMemorySide()
        trackRecovery(s)

        var obs = Observation(time: Double(MonotonicClock.nowNs()) / 1e9,
                              memory: s.memory.value?.rawValue, thermal: s.thermal.value?.rawValue,
                              onAC: s.battery.value?.onACPower, chargePercent: s.battery.value?.percent)
        obs.topApp = topObservedApp()
        if let bundle = engine.ingest(obs) { fire(bundle) }
    }

    private func topObservedApp() -> String? {
        guard let top = lastTopProcesses.max(by: { $0.residentBytes < $1.residentBytes }), top.residentBytes > 1_000_000_000 else { return nil }
        return String(format: "%@ %.1fGB", top.name, Double(top.residentBytes) / 1_073_741_824)
    }

    private func updateJob(_ s: SystemSnapshot) {
        var new: JobInfo?
        if suppressJob {
            new = nil
        } else if forcedCharging {
            new = JobInfo(label: "배터리 충전 (디버그 표시)", short: debugLongJob ? "ComfyUI 렌더링 · 남은 시간 약 12분" : "충전", percent: 62)
        } else if let b = s.battery.value, b.isCharging, b.onACPower {
            new = JobInfo(label: "배터리 충전", short: "충전", percent: b.percent)
        }
        if new != job { setAnimated { self.job = new } }
    }

    private func level(_ cause: AlertCause, _ s: SystemSnapshot) -> Int {
        switch cause {
        case .memory: return s.memory.value?.rawValue ?? 0
        case .thermal: return min(2, s.thermal.value?.rawValue ?? 0)
        case .charger: return 0
        }
    }

    /// 경고 단계가 정상으로 돌아오면 짧게 ✓ (회복 체크)
    private func trackRecovery(_ s: SystemSnapshot) {
        for cause in [AlertCause.memory, .thermal] {
            let now = level(cause, s)
            let before = prevDisplayLevel[cause] ?? 0
            prevDisplayLevel[cause] = now
            if before > 0, now == 0 {
                recovered.insert(cause)
                recoverTimers[cause]?.cancel()
                let item = DispatchWorkItem { [weak self] in self?.recovered.remove(cause); self?.faceTick() }
                recoverTimers[cause] = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: item)
                if event?.cause == cause { event = nil }
            }
        }
    }

    private func faceTick() { objectWillChange.send() }

    // MARK: 로그 스트림 (카드 아래쪽 3줄)

    private static let logTime: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    private func appendLog(_ level: LogLevel, _ text: String) {
        statusLog.append(time: Self.logTime.string(from: Date()), level: level, text: text)
    }

    /// 로그 한 줄이 새로 들어올 때마다 타이핑 연출(15fps, ~0.27초)이 돌아 그동안 뷰 그래프가 프레임마다 갱신된다 — 프로파일(30초 펼침 고정 idle)에서 이 연출 하나가
    /// 메인 스레드 활성 시간의 1/3(3초 주기 기준 708 → 462ms)이었다. 시안은 1초마다지만 그러면 idle 이 눈에 띄게 올라 4틱(4초)에 한 줄씩 넣는다.
    static let logEveryTicks = 4

    private func appendInfoLog(_ s: SystemSnapshot) {
        defer { logTick += 1 }
        guard logTick % Self.logEveryTicks == 0 else { return }
        appendLog(.info, StatusLogComposer.info(step: logStep, snapshot: s))
        logStep += 1
    }

    /// 펼칠 때 로그가 비어 있으면(첫 펼침) 현재 값으로 3줄을 채워 시작한다 — 자리가 비어 보이지 않게
    private func seedLog() {
        guard statusLog.lines.count < StatusLog.capacity else { return }
        for _ in statusLog.lines.count..<StatusLog.capacity {
            appendLog(.info, StatusLogComposer.info(step: logStep, snapshot: snapshot))
            logStep += 1
        }
    }

    // MARK: 알림

    private func fire(_ bundle: AlertBundle) {
        guard settings.alertsEnabled else { return }
        let e = bundle.primary
        let suffix = bundle.extraCount > 0 ? " · 추가 \(bundle.extraCount)건" : ""
        let text = e.text + suffix
        event = HeadlineEvent(text: text, level: e.cause == .charger ? 0 : (e.level >= 2 ? 2 : 1), cause: e.cause, extra: bundle.extraCount)
        alertText = text
        appendLog(.warn, text)
        eventTimer?.cancel()
        let hold: TimeInterval = e.cause == .charger ? 6 : 13
        let item = DispatchWorkItem { [weak self] in self?.event = nil }
        eventTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: item)

        postAccessibilityAnnouncement(text)

        guard machine.beginAlert() else { return }          // 펼침 중이면 카드 사건 줄만 갱신
        dropToken += 1
        let token = dropToken
        onLayoutChange?()
        if reduceMotion {
            drop = .pill
            machine.alertPillFormed()
        } else {
            drop = .falling
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.78) { [weak self] in
                guard let self, self.dropToken == token, self.phase == .alert else { return }
                self.drop = .pill
                self.machine.alertPillFormed()
            }
        }
    }

    private func endDrop(to: IslandPhase) {
        dropToken += 1
        let token = dropToken
        if to.isOpen || to == .hidden || reduceMotion { drop = .hidden; return }
        drop = .retract
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) { [weak self] in
            guard let self, self.dropToken == token, self.drop == .retract else { return }
            self.drop = .hidden
        }
    }

    private func postAccessibilityAnnouncement(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: 디버그 (메뉴에서 강제 트리거 — 실제 판정 경로를 그대로 탄다)

    func debugTrigger(_ cause: AlertCause) {
        engine = EventEngine()                // 반복 억제를 비우고 새로 시작
        switch cause {
        case .memory:
            forcedMemory = MemoryPressureLevel.critical.rawValue
            scheduleRelease(cause, after: 13) { [weak self] in self?.forcedMemory = nil }
        case .thermal:
            forcedThermal = ThermalLevel.serious.rawValue
            scheduleRelease(cause, after: 13) { [weak self] in self?.forcedThermal = nil }
        case .charger:
            // 연결 전환 한 번을 같은 엔진 경로로 흘려 넣는다
            var o = Observation(time: Double(MonotonicClock.nowNs()) / 1e9, onAC: false)
            _ = engine.ingest(o)
            o.time += 0.01; o.onAC = true; o.chargePercent = snapshot.battery.value?.percent ?? 87
            if let b = engine.ingest(o) { fire(b) }
            return
        }
        ingest(lastRaw, afterGap: false)
    }

    func debugSuppressJob() { suppressJob = true; updateJob(lastRaw); refreshMemorySide() }

    func debugToggleCharging() {
        forcedCharging.toggle()
        updateJob(lastRaw)
        refreshMemorySide()
    }

    /// 디버그: 긴 작업 라벨로 오른쪽 날개를 넘치게 해서 메모리 칸 이동을 확인한다
    func debugToggleLongJob() {
        debugLongJob.toggle()
        forcedCharging = true
        updateJob(lastRaw)
        refreshMemorySide()
    }

    /// 접힘 줄 오른쪽 끝 링 뒤에 붙는 작업 라벨(펼침에서만 보임)
    func jobLabelText(_ j: JobInfo) -> String { "\(j.short) \(j.percent)%" }

    func measureWord(_ text: String) -> CGFloat {
        if let w = wordWidthCache[text] { return w }
        let font = NSFont.monospacedSystemFont(ofSize: HeadMetrics.word, weight: .semibold)
        let w = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        wordWidthCache[text] = w
        return w
    }

    /// 각 요소의 글리프·글자 폭(간격은 `HeadSpacing` 이 정한다)
    private func headWidths() -> HeadContentWidths {
        let mem = display(.memory), th = display(.thermal)
        return HeadContentWidths(cpuIcon: HeadMetrics.cpuIcon, cpuValue: HeadMetrics.cpuValue,
                                 memIcon: HeadMetrics.memIcon, memValue: HeadMetrics.memValue, glyph: HeadMetrics.glyph,
                                 thermIcon: HeadMetrics.thermIcon,
                                 memWord: mem.checking ? 0 : measureWord(mem.value), thermWord: th.checking ? 0 : measureWord(th.value),
                                 ring: job == nil ? 0 : HeadMetrics.ring,
                                 label: job.map { measureWord(jobLabelText($0)) } ?? 0,
                                 cpuLabel: measureWord(HeadLabel.cpu), memLabel: measureWord(HeadLabel.mem), thermLabel: measureWord(HeadLabel.thermal))
    }

    /// 날개 폭 갱신 + 메모리 칸 위치: 좌우 내용 폭 차가 더 작은 배치(A: 메모리 오른쪽 / B: 왼쪽)를 고른다. **접힘 폭 기준 고정 판정**(펼침은 따라감),
    /// 오른쪽이 예산을 넘으면 B. A→B 즉시, B→A 는 16pt 이상 더 균형적인 상태가 1초 이상 지속될 때(히스테리시스).
    func refreshMemorySide() {
        let w = headWidths()
        let before = flow.side
        let side = flow.update(widths: w, now: ProcessInfo.processInfo.systemUptime)     // 접힘 폭 기준 고정 판정
        if side != before {
            trace("memory slot \(before) → \(side)")
            memorySide = side            // 페이드는 뷰의 .animation 이 맡는다(카메라 칸을 가로지르지 않음)
        }
        let cw = HeadSizing.wings(w, side: side, open: false), ow = HeadSizing.wings(w, side: side, open: true)
        let c = IslandLayout.Wings(left: ceil(cw.left), right: ceil(cw.right)), o = IslandLayout.Wings(left: ceil(ow.left), right: ceil(ow.right))
        if c != wings.collapsed || o != wings.open {
            setAnimated { self.wings = (c, o) }
            onLayoutChange?()
        }
    }

    private func scheduleRelease(_ cause: AlertCause, after: TimeInterval, _ body: @escaping () -> Void) {
        forceTimers[cause]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            body()
            if let s = self?.lastRaw { self?.ingest(s, afterGap: false) }
        }
        forceTimers[cause] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: item)
    }

    // MARK: 표시용 파생값

    /// 펼침 카드의 1분 추이(문자 그래프, 60칸). 기록이 짧으면 있는 만큼만(값 바로 옆에서 시작), 측정 못 한 구간은 `·`.
    /// CPU 는 0–100% 고정 축, 열·메모리는 단계(계단)라 단계 수에 맞춘 고정 눈금.
    func trendLine(_ kind: SlotKind) -> String {
        let bars = Array("▁▂▃▄▅▆▇█")
        let values: [Double?]
        let top: Double
        switch kind {
        case .cpu: values = history.cpu.values; top = 100
        case .thermal: values = history.thermal.values.map { $0.map(Double.init) }; top = 3
        case .memory: values = history.memory.values.map { $0.map(Double.init) }; top = 2
        }
        let line = values.map { v -> Character in
            guard let v else { return "·" }
            return bars[min(7, max(0, Int((v / top * 7).rounded())))]
        }
        return String(line)
    }

    /// 접힘 줄·툴팁·접근성에 쓰는 값. 접힘 줄에는 아이콘+값(모양)만 나오고, 단어는 `spoken` 에만 있다.
    func display(_ kind: SlotKind) -> SlotDisplay {
        switch kind {
        case .cpu:
            let v = snapshot.cpu.value.map { String(format: "%.0f%%", $0) } ?? "—"
            let c = snapshot.cpu.value == nil
            return SlotDisplay(glyph: "", value: v, pct: "", level: 0, spoken: c ? "CPU 확인 중" : "CPU \(v)", checking: c)
        case .thermal:
            guard let t = snapshot.thermal.value else {
                return SlotDisplay(glyph: ThemeStyle.glyphChecking, value: "", pct: "", level: 0, spoken: "열 상태 확인 중", checking: true)
            }
            let rec = recovered.contains(.thermal)
            return SlotDisplay(glyph: ThemeStyle.glyph(raw: t.rawValue, recovered: rec), value: t.label, pct: "", level: min(2, t.rawValue),
                               spoken: "열 상태 \(t.label)" + (rec ? " · 회복" : ""), checking: false)
        case .memory:
            let usage = snapshot.memoryUsage.value
            let pct = usage.map { String(format: "%.0f%%", MemoryMath.percent($0)) } ?? "—"
            guard let m = snapshot.memory.value else {
                return SlotDisplay(glyph: ThemeStyle.glyphChecking, value: "", pct: pct, level: 0, spoken: "메모리 사용 \(pct), 압박 확인 중", checking: true)
            }
            let rec = recovered.contains(.memory)
            return SlotDisplay(glyph: ThemeStyle.glyph(raw: m.rawValue, recovered: rec), value: m.label, pct: pct, level: m.rawValue,
                               spoken: "메모리 사용 \(pct), 압박 \(m.label)" + (rec ? " · 회복" : ""), checking: false)
        }
    }

    /// 카드 첫 줄: 현재 주의할 사항
    var headline: (text: String, level: Int) {
        if let e = event { return (e.text, e.level) }
        if snapshot.memory.status == .checking { return ("메모리 압박 확인 중", 0) }
        if (snapshot.thermal.value?.rawValue ?? 0) >= 1 { return ("열 상태 \(snapshot.thermal.value?.label ?? "") · 지켜보는 중", 1) }
        if (snapshot.memory.value?.rawValue ?? 0) >= 1 { return ("메모리 압박 \(snapshot.memory.value?.label ?? "") · 지켜보는 중", 1) }
        return ("현재 주의할 사항 없음", 0)
    }
}
