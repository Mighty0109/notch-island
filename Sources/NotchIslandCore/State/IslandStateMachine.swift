import Foundation

public protocol Cancellable { func cancel() }

public protocol Scheduler {
    @discardableResult
    func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) -> Cancellable
}

public final class DispatchScheduler: Scheduler {
    private final class Token: Cancellable {
        let item: DispatchWorkItem
        init(_ i: DispatchWorkItem) { item = i }
        func cancel() { item.cancel() }
    }
    public init() {}
    @discardableResult
    public func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) -> Cancellable {
        let item = DispatchWorkItem(block: block)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return Token(item)
    }
}

public enum IslandPhase: Equatable, Sendable {
    case collapsed      // 접힘
    case alert          // 물방울 알림
    case preview        // 호버 미리보기 (포커스 안 뺏음)
    case pinned         // 클릭 고정
    case hidden         // 전체화면·사용자 숨김 등

    public var isOpen: Bool { self == .preview || self == .pinned }
}

public enum PointerZone: Equatable, Sendable {
    case none, head, card, pill
}

/// 세 모드가 공유하는 상태 머신. UI·시계에서 독립(Scheduler 주입)이라 시간 규칙을 그대로 테스트할 수 있다.
public final class IslandStateMachine {
    public struct Timing: Equatable, Sendable {
        public var hoverDelay: TimeInterval = 0.30     // 호버 미리보기
        public var leaveDelay: TimeInterval = 0.35     // 이탈 후 접힘
        public var alertHold: TimeInterval = 3.0       // 알림 노출
        public init() {}
    }

    public private(set) var phase: IslandPhase = .collapsed
    public private(set) var alertExpired = false
    public var hoverEnabled = true
    public var onPhaseChange: ((_ from: IslandPhase, _ to: IslandPhase) -> Void)?
    /// 타이머 스케줄·발화·스킵 사유를 남기는 추적 훅(앱이 `NOTCH_ISLAND_TRACE` 일 때 연결)
    public var trace: ((String) -> Void)?

    private let scheduler: Scheduler
    private let timing: Timing
    private var hoverTimer: Cancellable?
    private var leaveTimer: Cancellable?
    private var alertTimer: Cancellable?
    private var zone: PointerZone = .none

    public init(scheduler: Scheduler, timing: Timing = Timing()) {
        self.scheduler = scheduler
        self.timing = timing
    }

    private var isInside: Bool { zone != .none }

    private func set(_ new: IslandPhase) {
        guard new != phase else { return }
        let old = phase
        phase = new
        if old == .alert { alertTimer?.cancel(); alertTimer = nil; alertExpired = false }
        onPhaseChange?(old, new)
    }

    // MARK: 포인터

    public func pointerMoved(_ newZone: PointerZone) {
        guard phase != .hidden else { zone = .none; return }
        let wasInside = isInside
        zone = newZone

        if isInside {
            leaveTimer?.cancel(); leaveTimer = nil
            if newZone == .pill { hoverTimer?.cancel(); hoverTimer = nil; return }   // 방울 위에선 알림만 붙잡는다
            if hoverEnabled, phase == .collapsed || phase == .alert, hoverTimer == nil {
                trace?("hoverTimer scheduled (\(Int(timing.hoverDelay * 1000))ms) zone=\(newZone)")
                hoverTimer = scheduler.schedule(after: timing.hoverDelay) { [weak self] in
                    guard let self else { return }
                    self.hoverTimer = nil
                    if self.isInside, self.zone != .pill, self.phase == .collapsed || self.phase == .alert {
                        self.trace?("hoverTimer fired → preview"); self.set(.preview)
                    } else { self.trace?("hoverTimer fired → skipped (inside=\(self.isInside) zone=\(self.zone) phase=\(self.phase))") }
                }
            }
        } else {
            hoverTimer?.cancel(); hoverTimer = nil
            guard wasInside else { trace?("leave ignored: machine zone was already none (phase=\(phase))"); return }
            leaveTimer?.cancel()
            trace?("leaveTimer scheduled (\(Int(timing.leaveDelay * 1000))ms) phase=\(phase)")
            leaveTimer = scheduler.schedule(after: timing.leaveDelay) { [weak self] in
                guard let self else { return }
                self.leaveTimer = nil
                guard !self.isInside else { self.trace?("leaveTimer fired → skipped: pointer inside (zone=\(self.zone))"); return }
                if self.phase == .preview { self.trace?("leaveTimer fired → collapse"); self.set(.collapsed) }
                else if self.phase == .alert, self.alertExpired { self.trace?("leaveTimer fired → collapse (expired alert)"); self.set(.collapsed) }
                else { self.trace?("leaveTimer fired → skipped: phase=\(self.phase) alertExpired=\(self.alertExpired)") }
            }
        }
    }

    // MARK: 조작

    public func click(_ z: PointerZone) {
        guard phase != .hidden else { return }
        switch z {
        case .head:
            set(phase == .pinned ? .collapsed : .pinned)
        case .card:
            if phase == .preview { set(.pinned) }
        case .pill:
            if phase == .alert { set(.pinned) }
        case .none:
            break
        }
    }

    /// Esc · 닫기 버튼
    public func close() {
        if phase.isOpen { set(.collapsed) }
    }

    // MARK: 알림

    /// - Returns: 물방울을 띄워야 하면 true. 이미 펼쳐져 있거나 숨김이면 false(카드 사건 줄만 갱신).
    @discardableResult
    public func beginAlert() -> Bool {
        switch phase {
        case .collapsed:
            set(.alert)
            alertExpired = false
            return true
        case .alert:
            alertTimer?.cancel(); alertTimer = nil
            alertExpired = false
            return true
        default:
            return false
        }
    }

    /// 방울이 알약으로 완성된 뒤부터 노출 시간을 센다.
    public func alertPillFormed() {
        guard phase == .alert else { return }
        alertTimer?.cancel()
        alertTimer = scheduler.schedule(after: timing.alertHold) { [weak self] in
            guard let self, self.phase == .alert else { return }
            self.alertTimer = nil
            if self.isInside { self.alertExpired = true } else { self.set(.collapsed) }
        }
    }

    // MARK: 숨김

    public func setHidden(_ hidden: Bool) {
        // 숨김 상태가 실제로 바뀔 때만 움직인다. (전체화면 감시가 2초마다·앱 전환마다 `setHidden(false)` 를 불러서,
        // 예전엔 이 호출이 진행 중인 이탈/호버 타이머를 무조건 지워 "빨리 빠져나가면 안 접힘" 결함이 났다)
        if hidden {
            guard phase != .hidden else { return }
            if hoverTimer != nil || leaveTimer != nil { trace?("setHidden(true) cancels pending timers") }
            hoverTimer?.cancel(); hoverTimer = nil
            leaveTimer?.cancel(); leaveTimer = nil
            zone = .none
            set(.hidden)
        } else if phase == .hidden {
            set(.collapsed)
        }
    }
}
