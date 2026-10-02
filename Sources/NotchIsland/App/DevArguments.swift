import AppKit
import NotchIslandCore

/// 개발·검증용 실행 인자 (README 참고). 평소 실행에는 영향이 없다.
///   --phase=collapsed|preview|pinned|alert-memory|alert-thermal|alert-charger
///   --demo-job   --demo-long-job   --no-job   --reduce-motion   --open-settings   --quit-after=SECONDS   --selftest
@MainActor
enum DevArguments {
    static func apply(model: IslandModel, settings: SettingsStore, panel: PanelController) {
        let args = CommandLine.arguments.dropFirst()
        func value(_ key: String) -> String? { args.first { $0.hasPrefix("--\(key)=") }.map { String($0.dropFirst(key.count + 3)) } }

        if args.contains("--demo-job") { model.debugToggleCharging() }
        if args.contains("--no-job") { model.debugSuppressJob() }
        if args.contains("--demo-long-job") { model.debugToggleLongJob() }
        if args.contains("--reduce-motion") { model.debugForceReduceMotion() }
        if args.contains("--open-settings") { NotificationCenter.default.post(name: .init("NotchIslandOpenSettings"), object: nil) }
        if let q = value("quit-after"), let secs = Double(q) {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { NSApp.terminate(nil) }
        }
        if let phase = value("phase") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                switch phase {
                case "pinned": model.click(.head)
                case "open-close":
                    model.click(.head)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { model.close() }
                case "preview": model.machine.pointerMoved(.head)      // 포인터가 머무는 것처럼 — 0.3초 뒤 미리보기
                case "alert-memory": model.debugTrigger(.memory)
                case "alert-thermal": model.debugTrigger(.thermal)
                case "alert-charger": model.debugTrigger(.charger)
                default: break
                }
            }
        }
        if args.contains("--selftest") { SelfTest.run(model: model, panel: panel) }
    }
}

/// 프로세스 안에서 합성 마우스·키 이벤트를 패널로 직접 보내 SwiftUI 제스처 경로(클릭 고정 · Esc 닫기)를 확인한다.
/// 외부 입력 주입(접근성 권한)이 필요 없다.
@MainActor
enum SelfTest {
    static func run(model: IslandModel, panel: PanelController) {
        func out(_ s: String) { print("SELFTEST \(s)"); fflush(stdout) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let p = panel.panel else { out("FAIL 패널 없음"); NSApp.terminate(nil); return }
            let l = model.layout
            func send(_ type: NSEvent.EventType, at pt: CGPoint, count: Int = 1) {
                let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: pt.x, y: p.frame.height - pt.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: p.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)
                if let e { p.sendEvent(e) }
            }
            func click(at pt: CGPoint) { send(.leftMouseDown, at: pt); send(.leftMouseUp, at: pt) }

            out("start phase=\(model.phase) island=\(l.island)")
            click(at: CGPoint(x: l.island.minX + 40, y: l.notchHeight / 2))        // 왼쪽 날개(CPU 칸) 클릭
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                out("click head → phase=\(model.phase) (기대: pinned) \(model.phase == .pinned ? "PASS" : "FAIL")")
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: p.windowNumber,
                                            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                    p.sendEvent(e)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    out("Esc → phase=\(model.phase) (기대: collapsed) \(model.phase == .collapsed ? "PASS" : "FAIL")")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
                }
            }
        }
    }
}
