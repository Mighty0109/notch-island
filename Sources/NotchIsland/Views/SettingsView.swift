import SwiftUI
import NotchIslandCore

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("동작") {
                Toggle("호버하면 펼치기 (0.3초 머무름)", isOn: $settings.hoverExpand)
                Toggle("알림 켜기 (메모리 압박 · 열 상태 · 충전기 연결)", isOn: $settings.alertsEnabled)
            }
            Section("옵션") {
                Toggle("로컬 모델 칸 (기본 꺼짐)", isOn: $settings.localModelEnabled)
                Text("v0.1 은 켜고 끄는 토글만 있습니다. 모델 목록 표시는 v0.2 에서 붙습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
