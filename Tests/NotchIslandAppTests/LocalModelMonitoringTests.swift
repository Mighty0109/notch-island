import XCTest
import Combine
@testable import NotchIsland
import NotchIslandCore

private actor CountingModelHTTP: LocalModelHTTPSource {
    private(set) var requests = 0
    func get(_ url: URL) async throws -> Data? {
        requests += 1
        return Data(#"{"data":[{"id":"org/Test-Model","loaded":true}]}"#.utf8)
    }
}

@MainActor
final class LocalModelMonitoringTests: XCTestCase {
    func testPollingFollowsExpansionSettingAndLifecycle() async throws {
        let suite = "com.mighty.notch-island.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.hoverExpand = false
        let http = CountingModelHTTP()
        let provider = LocalModelProvider(source: http, endpoints: [.init(engine: "MLX", port: 11234, format: .openAI)])
        let model = IslandModel(settings: settings, localModelProvider: provider)
        model.start()
        defer { model.stop() }
        try await Task.sleep(nanoseconds: 100_000_000)
        var count = await http.requests
        XCTAssertEqual(count, 0, "접힘일 때 조회하지 않음")

        model.click(.head)
        for _ in 0..<50 {
            if model.localModels.value != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.localModels.value?.first?.name, "org/Test-Model")
        count = await http.requests
        XCTAssertEqual(count, 1)
        var publishes = 0
        let sub = model.$localModels.dropFirst().sink { _ in publishes += 1 }
        defer { sub.cancel() }
        try await Task.sleep(nanoseconds: 5_100_000_000)
        count = await http.requests
        XCTAssertEqual(count, 2, "펼침 동안 5초마다 조회")
        XCTAssertEqual(publishes, 0, "모델 목록이 같으면 UI를 다시 그리지 않음")
        settings.localModelEnabled = false
        settings.localModelEnabled = true
        for _ in 0..<50 {
            if model.localModels.value != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        count = await http.requests
        XCTAssertEqual(count, 3, "다시 켜면 즉시 새로 조회")
        model.close()
        try await Task.sleep(nanoseconds: 5_100_000_000)
        count = await http.requests
        XCTAssertEqual(count, 3, "접으면 다음 주기의 조회를 취소")
        model.stop()
        model.click(.head)
        try await Task.sleep(nanoseconds: 100_000_000)
        count = await http.requests
        XCTAssertEqual(count, 3, "수집 중지 후에는 펼쳐도 조회하지 않음")
    }
}
