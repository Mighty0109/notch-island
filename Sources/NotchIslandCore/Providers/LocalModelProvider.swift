import Foundation
import Darwin

public struct LocalModelInfo: Equatable, Sendable {
    public var name: String
    public var engine: String
    public var port: Int
    public var activity: String

    public init(name: String, engine: String, port: Int, activity: String) {
        self.name = name; self.engine = engine; self.port = port; self.activity = activity
    }

    private var leaf: String {
        var leaf = name.split(separator: "/").last.map(String.init) ?? name
        for suffix in [".safetensors", ".gguf", ".ckpt"] where leaf.hasSuffix(suffix) {
            leaf.removeLast(suffix.count)
        }
        return leaf
    }

    private static let quantPattern = #"^(\d+bit|bf16|fp16|fp8|fp4|int8|int4|q\d+(_k(_[sml])?)?|q\d+_\d+)$"#
    private static let noiseTokens: Set<String> = ["mlx", "serve", "gguf", "uncensored", "abliterated"]

    /// 파일명 토큰을 이름 / 양자화로 분리한다. 하이픈 조각이 통째로 양자화 패턴이면(q4_k_m) 밑줄로 쪼개지 않는다.
    private var parsed: (name: String, quant: String) {
        var words: [String] = []
        var quants: [String] = []
        func isQuant(_ t: String) -> Bool { t.range(of: Self.quantPattern, options: [.regularExpression, .caseInsensitive]) != nil }
        for chunk in leaf.split(separator: "-").map(String.init) {
            if isQuant(chunk) { quants.append(chunk); continue }
            for t in chunk.split(separator: "_").map(String.init) {
                if isQuant(t) { quants.append(t) }
                else if !Self.noiseTokens.contains(t.lowercased()) { words.append(t) }
            }
        }
        guard let first = words.first else { return (leaf, quants.joined(separator: " ")) }
        let rest = words.dropFirst()
        let joined: String
        if !rest.isEmpty, first.range(of: #"^[A-Za-z]+\d"#, options: .regularExpression) != nil {
            joined = first + " " + rest.joined(separator: "-")
        } else {
            joined = words.joined(separator: "-")
        }
        return (joined, quants.joined(separator: " "))
    }

    public var displayName: String { parsed.name }

    public func shortName(maxCharacters: Int = 36) -> String {
        let s = displayName
        guard s.count > maxCharacters, maxCharacters >= 3 else { return s }
        let front = (maxCharacters - 1) * 2 / 3
        return String(s.prefix(front)) + "…" + String(s.suffix(maxCharacters - front - 1))
    }

    public var detail: String {
        let q = parsed.quant
        let place = port > 0 ? " :\(port)" : "" // 포트 없는 프로세스(TTS 등)는 포트 칸을 뺀다
        return q.isEmpty ? "\(engine)\(place) · \(activity)" : "\(engine) \(q)\(place) · \(activity)"
    }
}

public struct LocalModelEndpoint: Sendable {
    public enum Format: Sendable { case openAI, mlxHealth, ollama, comfyQueue }
    public var engine: String
    public var port: Int
    public var format: Format
    public init(engine: String, port: Int, format: Format) {
        self.engine = engine; self.port = port; self.format = format
    }
    public var url: URL {
        let path: String
        switch format {
        case .openAI: path = "/v1/models"
        case .mlxHealth: path = "/health"
        case .ollama: path = "/api/ps"
        case .comfyQueue: path = "/queue"
        }
        return URL(string: "http://127.0.0.1:\(port)\(path)")!
    }
    public static let defaults: [Self] = [
        .init(engine: "MLX", port: 11234, format: .openAI),
        .init(engine: "DS4", port: 8000, format: .openAI),
        .init(engine: "LFM", port: 8080, format: .mlxHealth),
        .init(engine: "MLX", port: 8081, format: .openAI),
        .init(engine: "Ollama", port: 11434, format: .ollama),
        .init(engine: "ComfyUI", port: 8188, format: .comfyQueue),
        .init(engine: "ComfyUI", port: 8190, format: .comfyQueue),
    ]
}

public protocol LocalModelHTTPSource: Sendable {
    /// nil: 서버 없음 / 지원하지 않는 경로. 읽기 요청만 허용한다.
    func get(_ url: URL) async throws -> Data?
}

private final class NoLocalRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // 로컬 서버가 외부 주소로 보내더라도 따라가지 않는다.
    }
}

public final class LocalModelHTTPClient: LocalModelHTTPSource, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2; c.timeoutIntervalForResource = 2
        c.httpCookieStorage = nil; c.urlCache = nil
        c.connectionProxyDictionary = [:]
        session = URLSession(configuration: c, delegate: NoLocalRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    public func get(_ url: URL) async throws -> Data? {
        guard url.host == "127.0.0.1", url.scheme == "http" else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 404 { return nil }
            guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
            return data
        } catch let e as URLError where e.code == .cannotConnectToHost || e.code == .cannotFindHost {
            return nil
        }
    }
}

/// 포트가 없는 로컬 모델 프로세스(MLX 오디오 등)를 argv 로 찾기 위한 읽기 전용 소스.
public protocol LocalModelProcessSource: Sendable {
    /// 후보 프로세스의 argv 목록. 읽을 수 없는 프로세스는 건너뛰고, 전체가 실패해도 빈 배열.
    func candidateArguments() -> [[String]]
}

public struct NoLocalModelProcesses: LocalModelProcessSource {
    public init() {}
    public func candidateArguments() -> [[String]] { [] }
}

/// libproc 으로 pid 를 모으고 `sysctl KERN_PROCARGS2` 로 argv 를 읽는다(같은 사용자 프로세스만).
/// 비용을 줄이려고 proc_name 이 python 계열인 프로세스만 읽는다.
public struct LibprocArgvSource: LocalModelProcessSource {
    public init() {}

    static func isPythonName(_ name: String) -> Bool { name.lowercased().hasPrefix("python") }

    public func candidateArguments() -> [[String]] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 32)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        var out: [[String]] = []
        var nameBuf = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(got) / MemoryLayout<pid_t>.size) where pid > 0 {
            guard proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0,
                  Self.isPythonName(String(cString: nameBuf)),
                  let argv = Self.readArguments(pid: pid) else { continue }
            out.append(argv)
        }
        return out
    }

    private static let maxArgsBytes = 4 << 20

    static func readArguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size, size <= maxArgsBytes else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 0 else { return nil }
        return LocalModelProcessParser.parseProcArgs(Array(buf.prefix(size)))
    }
}

/// 프로세스 argv 판정·파싱(순수 함수).
public enum LocalModelProcessParser {
    /// KERN_PROCARGS2 버퍼: argc(Int32) + exec 경로 + NUL 패딩 + argv[0..<argc] (각 NUL 종료) + 환경변수.
    /// 범위를 넘으면 nil.
    public static func parseProcArgs(_ buf: [UInt8]) -> [String]? {
        let head = MemoryLayout<Int32>.size
        guard buf.count > head else { return nil }
        var argcRaw: Int32 = 0
        withUnsafeMutableBytes(of: &argcRaw) { dst in
            for i in 0..<head { dst[i] = buf[i] }
        }
        let argc = Int(argcRaw)
        guard argc > 0, argc <= 4096 else { return nil }
        var i = head
        while i < buf.count, buf[i] != 0 { i += 1 }   // exec 경로
        while i < buf.count, buf[i] == 0 { i += 1 }   // NUL 패딩
        var args: [String] = []
        while args.count < argc, i < buf.count {
            var j = i
            while j < buf.count, buf[j] != 0 { j += 1 }
            args.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return args.count == argc ? args : nil
    }

    /// `mlx_audio` 를 쓰는 python 프로세스면 TTS 모델 정보, 아니면 nil.
    public static func audioModel(argv: [String]) -> LocalModelInfo? {
        guard argv.contains(where: { $0.contains("mlx_audio") }) else { return nil }
        var path: String?
        var k = 0
        while k < argv.count {
            let a = argv[k]
            if a == "--model", k + 1 < argv.count { path = argv[k + 1]; break }
            if a.hasPrefix("--model=") { path = String(a.dropFirst("--model=".count)); break }
            k += 1
        }
        let name = path.flatMap(modelName(fromPath:)) ?? "mlx_audio"
        return LocalModelInfo(name: name, engine: "TTS", port: 0, activity: "실행 중")
    }

    /// 포트 없는 이미지·영상 생성 스크립트(정해진 목록만). 목록 밖 python 은 nil.
    /// 프롬프트·출력 경로에 단어가 섞여도 잡히지 않도록 스크립트 판정은 hasSuffix 로 한다.
    public static func generatorModel(argv: [String]) -> LocalModelInfo? {
        func info(_ name: String, _ engine: String) -> LocalModelInfo {
            LocalModelInfo(name: name, engine: engine, port: 0, activity: "생성 중")
        }
        if argv.contains(where: { $0.contains("minimax-h3-mlx") && $0.hasSuffix("generate.py") }) {
            return info("MiniMax-H3", "MLX")
        }
        if argv.contains(where: { $0.split(separator: "/").last?.hasPrefix("mflux-") == true }) {
            return info("mflux", "MLX")
        }
        if argv.contains(where: { $0.contains("iris-3b-turbo") && $0.hasSuffix("sample.py") }) {
            return info("Iris-3B", "Torch")
        }
        return nil
    }

    /// HF 캐시 `.../models--<org>--<name>/snapshots/<hash>` 면 `<name>`, 아니면 경로의 마지막 의미 있는 조각.
    static func modelName(fromPath path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        for part in parts where part.hasPrefix("models--") {
            let pieces = part.components(separatedBy: "--")
            if pieces.count >= 3, let last = pieces.last, !last.isEmpty { return last }
        }
        let skip: Set<String> = ["snapshots", "main", ".", ".."]
        for part in parts.reversed() {
            if skip.contains(part) { continue }
            if part.count >= 7, part.allSatisfy({ $0.isHexDigit }) { continue } // 스냅샷 해시
            return part
        }
        return nil
    }
}

/// 모델 로드·생성 없이 로드 상태/실행 큐만 읽는다. 호출 주기는 화면 모델이 펼침 동안 5초로 제한한다.
public struct LocalModelProvider: Sendable {
    private let source: any LocalModelHTTPSource
    private let endpoints: [LocalModelEndpoint]
    private let processes: any LocalModelProcessSource
    public init(source: any LocalModelHTTPSource = LocalModelHTTPClient(), endpoints: [LocalModelEndpoint] = LocalModelEndpoint.defaults,
                processes: any LocalModelProcessSource = LibprocArgvSource()) {
        self.source = source; self.endpoints = endpoints; self.processes = processes
    }

    public func sample(now: Date = Date()) async -> Reading<[LocalModelInfo]> {
        let results = await withTaskGroup(of: ([LocalModelInfo], Bool).self, returning: [([LocalModelInfo], Bool)].self) { group in
            for endpoint in endpoints {
                group.addTask {
                    do {
                        guard let data = try await source.get(endpoint.url) else { return ([], false) }
                        return (try Self.decode(data, endpoint: endpoint), false)
                    } catch { return ([], true) }
                }
            }
            // 포트 없는 프로세스: 읽기 실패는 조용히 건너뛰므로 실패 플래그는 항상 false.
            group.addTask {
                var seen = Set<String>()
                let infos = processes.candidateArguments().flatMap { argv in
                    [LocalModelProcessParser.audioModel(argv: argv), LocalModelProcessParser.generatorModel(argv: argv)].compactMap { $0 }
                }.filter { seen.insert($0.name).inserted }
                return (infos, false)
            }
            var results: [([LocalModelInfo], Bool)] = []
            for await result in group { results.append(result) }
            return results
        }
        var models = results.flatMap { $0.0 }
        // 포트 없는 프로세스(port 0)는 서버 뒤로.
        models.sort { (($0.port == 0 ? Int.max : $0.port), $0.name) < (($1.port == 0 ? Int.max : $1.port), $1.name) }
        if models.isEmpty, results.contains(where: { $0.1 }) {
            return .failed("일부 서버 확인 실패", unit: "models", at: now, source: "loopback GET")
        }
        return .ok(models, unit: "models", at: now, source: "loopback GET")
    }

    public static func decode(_ data: Data, endpoint: LocalModelEndpoint) throws -> [LocalModelInfo] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        var names: [String] = []
        let activity: String
        switch endpoint.format {
        case .openAI:
            guard let items = root["data"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
            names = items.compactMap { item in
                // OpenAI 모델 목록은 디스크 캐시/등록 목록일 수도 있다. 로드 증거 없는 ID는 제외한다.
                if let loaded = item["loaded"] as? Bool {
                    return loaded ? item["id"] as? String : nil
                }
                // ds4.c는 단일 로드 엔진을 여러 API 별칭으로 반환한다. 실제 엔진 이름으로 합친다.
                if endpoint.engine == "DS4", item["owned_by"] as? String == "ds4.c" {
                    return item["name"] as? String
                }
                return nil
            }
            activity = "로드됨"
        case .mlxHealth:
            // mlx_vlm /v1/models는 HF 캐시 전체를 반환하므로 /health의 실제 모델 캐시만 읽는다.
            guard root.keys.contains("loaded_model") || root.keys.contains("loaded_models") else {
                throw URLError(.cannotParseResponse)
            }
            func appendModel(_ value: Any?) throws {
                guard let value, !(value is NSNull) else { return }
                guard let name = value as? String else { throw URLError(.cannotParseResponse) }
                names.append(name)
            }
            try appendModel(root["loaded_model"])
            if let value = root["loaded_models"] {
                guard let caches = value as? [String: [String: Any]] else { throw URLError(.cannotParseResponse) }
                for cache in caches.values { try appendModel(cache["model"]) }
            }
            activity = "로드됨"
        case .ollama:
            guard let items = root["models"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
            names = items.compactMap { ($0["name"] ?? $0["model"]) as? String }; activity = "로드됨"
        case .comfyQueue:
            guard let tasks = root["queue_running"] as? [[Any]] else { throw URLError(.cannotParseResponse) }
            for task in tasks where task.count > 2 {
                guard let prompt = task[2] as? [String: [String: Any]] else { continue }
                for node in prompt.values {
                    guard let inputs = node["inputs"] as? [String: Any] else { continue }
                    // 본체 모델만: 대기 큐·완료 기록·LoRA·VAE·업스케일러는 실행 모델로 세지 않는다.
                    for key in ["unet_name", "ckpt_name", "diffusion_model_name"] {
                        if let name = inputs[key] as? String { names.append(name) }
                    }
                }
            }
            activity = "실행 중"
        }
        return Set(names.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).sorted().map {
            LocalModelInfo(name: $0, engine: endpoint.engine, port: endpoint.port, activity: activity)
        }
    }
}
