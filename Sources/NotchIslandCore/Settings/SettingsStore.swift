import Foundation
import Combine

/// UserDefaults 설정. 버전 키가 있어 이후 스키마가 바뀌어도 옛 값을 안전하게 이전한다.
public final class SettingsStore: ObservableObject {
    public static let currentVersion = 2
    enum Key {
        static let version = "settingsVersion"
        static let legacyTheme = "theme"      // v1 의 모드 선택(귀여운·화려한·매트릭스). v2 부터 매트릭스 하나라 버린다
        static let hover = "hoverExpand"
        static let alerts = "alertsEnabled"
        static let localModel = "localModelEnabled"
    }

    private let defaults: UserDefaults

    @Published public var hoverExpand: Bool { didSet { defaults.set(hoverExpand, forKey: Key.hover) } }
    @Published public var alertsEnabled: Bool { didSet { defaults.set(alertsEnabled, forKey: Key.alerts) } }
    /// 로컬 모델 칸 — v0.1 은 토글만(표시 준비). 기본 꺼짐.
    @Published public var localModelEnabled: Bool { didSet { defaults.set(localModelEnabled, forKey: Key.localModel) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 버전 키가 없으면 첫 실행. v1 → v2: 옛 모드 값은 지운다(어떤 값이 있어도 매트릭스 하나)
        let version = defaults.integer(forKey: Key.version)
        if version < Self.currentVersion {
            defaults.removeObject(forKey: Key.legacyTheme)
            defaults.set(Self.currentVersion, forKey: Key.version)
        }
        hoverExpand = defaults.object(forKey: Key.hover) as? Bool ?? true
        alertsEnabled = defaults.object(forKey: Key.alerts) as? Bool ?? true
        localModelEnabled = defaults.object(forKey: Key.localModel) as? Bool ?? false
    }
}
