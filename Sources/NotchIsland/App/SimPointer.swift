import AppKit
import NotchIslandCore

/// 측정용 가짜 포인터(`--sim-pointer <시나리오>`). 실제 커서·키·클릭을 만들지 않고, 앱 안의 타이머가 가짜 좌표를
/// 전역 마우스 모니터가 부르는 것과 같은 경로(`PanelController.evaluatePointer(at:)`)로 90Hz 주입한다.
/// 이 모드에서는 실제 이벤트 모니터·메뉴바 아이콘을 만들지 않고 패널은 투명(alpha 0)·항상 클릭 통과라 화면에 안 보이고 마우스도 안 가로챈다.
///   --sim-pointer idle | far-move | island-move | pinned-idle | hover-cycle     (공백·`=` 둘 다 가능)
///   hover-cycle = 섬 위에 1.2초 머물다(호버 → 미리보기 펼침) 패널 밖으로 0.8초 나가기(접힘)를 반복 — 섬 위를 오가는 실사용에 가깝다
///   --sim-window-events   섬 위 좌표마다 패널 창에도 같은 mouseMoved NSEvent 를 앱 안에서 보낸다(SwiftUI 이벤트 처리 비용 근사. 실제 커서 아님)
enum SimScenario: String {
    case idle, farMove = "far-move", islandMove = "island-move", pinnedIdle = "pinned-idle", hoverCycle = "hover-cycle"

    static func parse(_ args: [String]) -> SimScenario? {
        for (i, a) in args.enumerated() {
            if a == "--sim-pointer", i + 1 < args.count { return SimScenario(rawValue: args[i + 1]) }
            if a.hasPrefix("--sim-pointer=") { return SimScenario(rawValue: String(a.dropFirst("--sim-pointer=".count))) }
        }
        return nil
    }
}

@MainActor
final class SimPointerDriver {
    static let hz = 90.0
    static let speed = 1100.0          // 초당 px — 손으로 빠르게 쓸어 넘기는 정도
    private let scenario: SimScenario
    private let panel: PanelController
    private let model: IslandModel
    private let sendWindowEvents: Bool
    private var timer: DispatchSourceTimer?
    private var t0 = ProcessInfo.processInfo.systemUptime

    init(scenario: SimScenario, panel: PanelController, model: IslandModel, sendWindowEvents: Bool) {
        self.scenario = scenario; self.panel = panel; self.model = model; self.sendWindowEvents = sendWindowEvents
    }

    func start() {
        // 시작 자리: 패널 밖 먼 곳(가만히 있는 시나리오의 주차 위치)
        panel.simulate(localPoint: Self.parked(model), sendWindowEvent: false)
        switch scenario {
        case .idle, .pinnedIdle: return
        case .farMove, .islandMove, .hoverCycle: break
        }
        t0 = ProcessInfo.processInfo.systemUptime
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / Self.hz, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        timer = t
        t.resume()
    }

    /// 패널 안 좌표(왼쪽 위 원점)로 본 "먼 곳": 패널 아래
    static func parked(_ model: IslandModel) -> CGPoint {
        let l = model.layout
        return CGPoint(x: IslandLayout.panelWidth / 2, y: IslandLayout.panelHeight(notchHeight: l.notchHeight) + 130)
    }

    private func tick() {
        let l = model.layout
        let t = ProcessInfo.processInfo.systemUptime - t0
        let cx = IslandLayout.panelWidth / 2
        let (y, half, wobble): (Double, Double, Double)
        switch scenario {
        case .farMove: (y, half, wobble) = (Double(IslandLayout.panelHeight(notchHeight: l.notchHeight)) + 130, 320, 14)
        case .islandMove: (y, half, wobble) = (Double(l.notchHeight) / 2, 190, 6)
        case .hoverCycle:
            // 2초 주기: 앞 1.2초는 섬 위(머무름), 뒤 0.8초는 패널 밖
            if t.truncatingRemainder(dividingBy: 2.0) >= 1.2 {
                panel.simulate(localPoint: Self.parked(model), sendWindowEvent: false)
                return
            }
            (y, half, wobble) = (Double(l.notchHeight) / 2, 60, 4)
        default: return
        }
        let period = 4 * half / Self.speed
        let ph = (t / period).truncatingRemainder(dividingBy: 1)
        let tri = ph < 0.5 ? (ph * 4 - 1) : (3 - ph * 4)         // -1...1 삼각파
        panel.simulate(localPoint: CGPoint(x: Double(cx) + tri * half, y: y + sin(t * 7) * wobble), sendWindowEvent: sendWindowEvents)
    }
}
