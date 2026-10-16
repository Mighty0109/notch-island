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
                Toggle("로컬 모델 이름 표시", isOn: $settings.localModelEnabled)
                Text("펼침 동안 5초마다 로컬 서버 목록과 ComfyUI 실행 큐를 확인합니다. 모델 이름과 엔진·포트를 표시합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
