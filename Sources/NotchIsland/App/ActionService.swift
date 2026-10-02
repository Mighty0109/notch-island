import AppKit

/// 동작 서비스: 사용자가 누를 때만 일어나는 행동. 스토어 빌드에서도 허용되는 것만 둔다
/// (다른 앱 종료 같은 행동은 v0.1 범위 밖이고 여기에 없다).
enum ActionService {
    static func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}
