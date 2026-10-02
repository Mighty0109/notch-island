import AppKit
import SwiftUI
import Combine
import NotchIslandCore

/// 테두리 없는 비활성 패널: 포커스를 안 뺏고, 모든 Spaces 에 뜨고, 메뉴바 위 레벨.
final class NotchPanel: NSPanel {
    var allowKey = false
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }

    /// 메뉴바 영역(화면 맨 위)에 놓기 위해 AppKit 의 자동 보정을 끈다
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class PanelController {
    private let model: IslandModel
    private(set) var panel: NotchPanel?
    private var monitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []
    private var fullscreenTimer: Timer?
    private var pollTimer: Timer?       // 펼쳐진 동안만 10Hz 로 포인터를 다시 본다(이탈 이벤트 누락 방지). 접힘일 땐 없음
    private var lastZone: PointerZone = .none
    private(set) var inputPassThrough = true      // 지금 패널이 클릭을 통과시키는 상태인가 (검증용)
    /// 측정 모드(`--sim-pointer`): 실제 이벤트 모니터를 끄고, 패널은 투명·항상 클릭 통과, 포인터는 `simulate` 로만 들어온다
    let simulated: Bool
    private var simLocation: CGPoint?             // 가짜 포인터(화면 좌표, 왼쪽 아래 원점)

    init(model: IslandModel, simulated: Bool = false) { self.model = model; self.simulated = simulated }

    func start() {
        buildPanel()
        if !simulated { installMonitors() }
        model.onLayoutChange = { [weak self] in self?.layoutChanged() }
        model.$phase.removeDuplicates().sink { [weak self] p in
            DispatchQueue.main.async { self?.phaseChanged(p) }
        }.store(in: &cancellables)

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenChanged() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluateFullscreen() }
            }
        }
        fullscreenTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateFullscreen() }
        }
        fullscreenTimer?.tolerance = 0.5
        evaluateFullscreen()
    }

    // MARK: 패널

    private func buildPanel() {
        let size = panelSize()
        let p = NotchPanel(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        p.acceptsMouseMovedEvents = true
        p.ignoresMouseEvents = true                 // 시작은 전부 통과. 그려진 영역 위에 포인터가 올 때만 받는다
        p.isReleasedWhenClosed = false
        if simulated { p.alphaValue = 0 }           // 측정 인스턴스는 화면에 안 보인다
        p.onEscape = { [weak self] in self?.model.close() }

        let host = NSHostingView(rootView: IslandRootView(model: model))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        panel = p
        reposition()
        if model.geometry != nil { p.orderFrontRegardless() }
    }

    private func panelSize() -> NSSize {
        NSSize(width: IslandLayout.panelWidth, height: IslandLayout.panelHeight(notchHeight: model.geometry?.notchHeight ?? 38))
    }

    func reposition() {
        guard let panel else { return }
        guard let g = model.geometry else { panel.orderOut(nil); return }
        let size = panelSize()
        // 정수 pt 로 맞춘다: 반 픽셀에 걸리면 글자가 흐려진다
        let origin = NSPoint(x: (g.centerX - size.width / 2).rounded(), y: (g.screenFrame.maxY - size.height).rounded())
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if model.phase != .hidden { panel.orderFrontRegardless() }
    }

    private func screenChanged() {
        model.updateGeometry()
        reposition()
        model.systemDidWake()          // 화면 구성이 바뀌면 누적 기준점을 버린다(가짜 급등 방지)
    }

    private func phaseChanged(_ p: IslandPhase) {
        guard let panel else { return }
        switch p {
        case .hidden:
            panel.orderOut(nil)
        default:
            if !panel.isVisible, model.geometry != nil { panel.orderFrontRegardless() }
        }
        // 고정 중에만 키 입력(Esc)을 받는다. 미리보기·알림은 포커스를 뺏지 않는다.
        if p == .pinned {
            panel.allowKey = true
            panel.makeKey()
        } else if panel.allowKey {
            panel.allowKey = false
            panel.resignKey()
        }
        updatePollTimer()
        evaluatePointer()
    }

    private func layoutChanged() { evaluatePointer() }

    // MARK: 입력 — 그려진 영역만 받는다

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluatePointer() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.evaluatePointer() }
            return e
        }) { monitors.append(l) }
        // 고정 중 카드·노치 바깥을 누르면 닫는다. 전역 모니터는 이벤트를 가로채지 않으므로 클릭은 그 앱에 그대로 전달된다.
        let down: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: down, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.closeIfClickedOutside() }
        }) { monitors.append(g) }
    }

    /// 실제 커서 위치(화면 좌표). 측정 모드에서는 가짜 포인터만 본다 — 실제 커서는 읽지도 않는다.
    private func pointerLocation() -> CGPoint { simulated ? (simLocation ?? .zero) : NSEvent.mouseLocation }

    /// 측정 모드 입력: 패널 안 좌표(왼쪽 위 원점)의 가짜 포인터를 놓고 전역 모니터와 같은 경로로 평가한다.
    func simulate(localPoint p: CGPoint, sendWindowEvent: Bool) {
        guard simulated, let panel else { return }
        let f = panel.frame
        simLocation = CGPoint(x: f.minX + p.x, y: f.maxY - p.y)
        evaluatePointer()
        // 섬 위일 때만 패널 창이 이벤트를 받는다(실제로도 그때만 ignoresMouseEvents=false). 앱 안에서 직접 전달 — 실제 입력 아님
        if sendWindowEvent, lastZone != .none,
           let e = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: p.x, y: f.height - p.y), modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            panel.sendEvent(e)
        }
    }

    private func closeIfClickedOutside() {
        guard model.phase == .pinned, let panel else { return }
        let loc = NSEvent.mouseLocation
        let f = panel.frame
        let zone = model.layout.zone(at: CGPoint(x: loc.x - f.minX, y: f.maxY - loc.y))
        model.trace("mouseDown zone=\(zone) phase=\(model.phase)")
        if zone == .none { model.close() }
    }

    /// 펼쳐진 동안만 도는 10Hz 재평가
    private func updatePollTimer() {
        if model.phase.isOpen {
            guard pollTimer == nil else { return }
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluatePointer(force: true) }
            }
            t.tolerance = 0.02
            RunLoop.main.add(t, forMode: .common)
            pollTimer = t
        } else {
            pollTimer?.invalidate(); pollTimer = nil
        }
    }

    /// 포인터가 어느 구역 위인지 계산해 상태 머신에 알리고, 그려진 영역 밖이면 패널이 클릭을 통과시키게 한다.
    func evaluatePointer(force: Bool = false) {
        guard let panel else { return }
        let loc = pointerLocation()
        let f = panel.frame
        // 패널 밖이고 이미 통과 상태면 할 일이 없다 — 마우스가 멀리 움직일 때 비용을 거의 안 쓴다
        if !force, inputPassThrough, lastZone == .none, !f.insetBy(dx: -2, dy: -2).contains(loc) { return }
        let p = CGPoint(x: loc.x - f.minX, y: f.maxY - loc.y)
        let zone = model.layout.zone(at: p)
        if zone != lastZone { model.trace("zone \(lastZone) → \(zone) at (\(Int(p.x)),\(Int(p.y))) phase=\(model.phase)") }
        lastZone = zone
        let pass = zone == .none
        if !simulated, panel.ignoresMouseEvents != pass { panel.ignoresMouseEvents = pass }
        inputPassThrough = pass
        model.pointerMoved(zone)
    }

    // MARK: 전체화면

    private func evaluateFullscreen() {
        guard let id = model.geometry?.displayID else { return }
        model.setSystemHidden(FullscreenDetector.isFullscreenAppShown(on: id))
    }

    func tearDown() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        fullscreenTimer?.invalidate()
        pollTimer?.invalidate()
    }
}

/// 다른 앱이 이 화면 전체를 덮고 있나. 창 목록의 위치·크기만 쓰므로 화면 기록 권한이 필요 없다.
enum FullscreenDetector {
    static func isFullscreenAppShown(on displayID: CGDirectDisplayID) -> Bool {
        let bounds = CGDisplayBounds(displayID)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
                  let width = b["Width"] as? CGFloat, let height = b["Height"] as? CGFloat else { continue }
            if abs(x - bounds.minX) < 1, abs(y - bounds.minY) < 1, abs(width - bounds.width) < 1, abs(height - bounds.height) < 1 { return true }
        }
        return false
    }
}
