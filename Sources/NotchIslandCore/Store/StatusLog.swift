import Foundation

public enum LogLevel: String, Equatable, Sendable { case info, warn }

public struct LogLine: Equatable, Identifiable, Sendable {
    public let id: Int
    public let time: String          // HH:mm:ss
    public let level: LogLevel
    public let text: String
    public init(id: Int, time: String, level: LogLevel, text: String) {
        self.id = id; self.time = time; self.level = level; self.text = text
    }
}

/// 카드 아래쪽 로그 스트림 — 최근 3줄만 들고 있다(오래된 줄은 위로 밀려 사라진다). 가짜 줄은 만들지 않는다: 줄 내용은 전부 실제 측정값·알림 문구.
public struct StatusLog: Equatable, Sendable {
    public static let capacity = 3
    public private(set) var lines: [LogLine] = []
    private var nextID = 0
    public init() {}

    @discardableResult
    public mutating func append(time: String, level: LogLevel, text: String) -> LogLine {
        let l = LogLine(id: nextID, time: time, level: level, text: text)
        nextID += 1
        lines.append(l)
        if lines.count > Self.capacity { lines.removeFirst(lines.count - Self.capacity) }
        return l
    }
}

/// 로그 한 줄 문구 만들기: `step % 3` 으로 CPU · 메모리 · 열·디스크를 돌려가며 현재 값을 적는다.
public enum StatusLogComposer {
    public static func info(step: Int, snapshot s: SystemSnapshot) -> String {
        switch ((step % 3) + 3) % 3 {
        case 0:
            guard let cpu = s.cpu.value else { return "cpu 확인 중" }
            let top = s.topProcesses.value?.first.map { " · 상위 \($0.name)" } ?? ""
            return String(format: "cpu %.0f%%", cpu) + top
        case 1:
            let pressure = s.memory.value.map { " · 압박 \($0.label)" } ?? " · 압박 확인 중"
            guard let u = s.memoryUsage.value else { return "mem 확인 중" + pressure }
            return String(format: "mem %.1f/%.0fG", Double(u.usedBytes) / MemoryMath.bytesPerGB, Double(u.totalBytes) / MemoryMath.bytesPerGB) + pressure
        default:
            let th = s.thermal.value.map { "thermal \($0.label)" } ?? "thermal 확인 중"
            let disk = s.disk.value.map { String(format: " · disk %.0fG 남음", $0.freeGB) } ?? ""
            return th + disk
        }
    }
}
