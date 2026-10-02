import AppKit
import SwiftUI
import NotchIslandCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: SettingsStore!
    private var model: IslandModel!
    private var panelController: PanelController!
    private var statusController: StatusItemController?
    private var settingsWindow: NSWindow?
    private var simDriver: SimPointerDriver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)          // 독 아이콘 없음 (LSUIElement 와 같은 효과)

        // 검증용: 실제 설정을 건드리지 않도록 별도 defaults 도메인을 쓸 수 있다
        let defaults = ProcessInfo.processInfo.environment["NOTCH_ISLAND_DEFAULTS_SUITE"].flatMap(UserDefaults.init(suiteName:)) ?? .standard
        settings = SettingsStore(defaults: defaults)
        model = IslandModel(settings: settings)
        let sim = SimScenario.parse(CommandLine.arguments)
        panelController = PanelController(model: model, simulated: sim != nil)
        if sim == nil {          // 측정 모드(--sim-pointer)에선 메뉴바 아이콘도 만들지 않는다
            statusController = StatusItemController(model: model)
            statusController?.openSettings = { [weak self] in self?.showSettings() }
        }

        panelController.start()
        model.start()

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.systemDidWake() }
        }

        NotificationCenter.default.addObserver(forName: .init("NotchIslandOpenSettings"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showSettings() }
        }
        DevArguments.apply(model: model, settings: settings, panel: panelController)
        if let sim {
            simDriver = SimPointerDriver(scenario: sim, panel: panelController, model: model,
                                         sendWindowEvents: CommandLine.arguments.contains("--sim-window-events"))
            simDriver?.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
        panelController?.tearDown()
    }

    private func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(settings: settings))
            let w = NSWindow(contentViewController: host)
            w.title = "Notch Island 설정"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
