import AppKit
import NotchIslandCore

/// 메뉴바 아이콘: 설정 · 숨기기 · 종료 (+ 디버그 강제 트리거). 노치가 안 보이는 상황에서도 항상 접근할 수 있는 탈출구.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: IslandModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let hideItem = NSMenuItem(title: "섬 숨기기", action: nil, keyEquivalent: "")
    var openSettings: (() -> Void)?

    init(model: IslandModel) {
        self.model = model
        super.init()
        if let b = item.button {
            b.image = LogoImage.menuBarImage()   // 템플릿 이미지(isTemplate = true) · 접근성 "Notch Island" — Support/LogoImage.swift
            b.toolTip = "Notch Island"
        }
        menu.delegate = self
        let settings = NSMenuItem(title: "설정…", action: #selector(settingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        hideItem.target = self; hideItem.action = #selector(toggleHide)
        menu.addItem(hideItem)
        menu.addItem(.separator())

        let debug = NSMenu()
        for (title, sel) in [("메모리 압박 알림 강제", #selector(debugMemory)), ("열 상태 알림 강제", #selector(debugThermal)),
                             ("충전기 연결 알림 강제", #selector(debugCharger)), ("충전 진행 팟 표시 켜기/끄기 (가짜)", #selector(debugJob)), ("긴 진행 라벨 켜기/끄기 (메모리 칸 이동 확인)", #selector(debugLongJob))] {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            debug.addItem(mi)
        }
        let dbg = NSMenuItem(title: "디버그", action: nil, keyEquivalent: "")
        dbg.submenu = debug
        menu.addItem(dbg)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Notch Island 종료", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        hideItem.title = model.isUserHidden ? "섬 보이기" : "섬 숨기기"
    }

    @objc private func settingsAction() { openSettings?() }
    @objc private func toggleHide() { model.setUserHidden(!model.isUserHidden) }
    @objc private func debugMemory() { model.debugTrigger(.memory) }
    @objc private func debugThermal() { model.debugTrigger(.thermal) }
    @objc private func debugCharger() { model.debugTrigger(.charger) }
    @objc private func debugLongJob() { model.debugToggleLongJob() }
    @objc private func debugJob() { model.debugToggleCharging() }
    @objc private func quitAction() { NSApp.terminate(nil) }
}
