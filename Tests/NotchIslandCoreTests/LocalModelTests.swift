import XCTest
@testable import NotchIslandCore

final class LocalModelTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testLoadedServerModelsPreserveFullIDAndDeduplicate() throws {
        let e = LocalModelEndpoint(engine: "MLX", port: 11234, format: .openAI)
        let models = try LocalModelProvider.decode(data(#"{"data":[{"id":"org/Qwen-Flash-4bit","loaded":true},{"id":"org/Qwen-Flash-4bit","loaded":true},{"id":"","loaded":true},{"id":"cached-model","loaded":false},{"id":"unknown-model"}]}"#), endpoint: e)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].name, "org/Qwen-Flash-4bit")
        XCTAssertEqual(models[0].displayName, "Qwen-Flash")
        XCTAssertEqual(models[0].detail, "MLX 4bit :11234 · 로드됨")
    }

    func testCachedOpenAIModelsAreNeverAssumedLoaded() throws {
        let e = LocalModelEndpoint(engine: "MLX", port: 8081, format: .openAI)
        let json = #"{"data":[{"id":"LiquidAI/LFM2.5-VL-3B-MLX-4bit"},{"id":"krea/Krea-2-Turbo"},{"id":"aac6fef/laya-multilingual-mlx"},{"id":"loading","loaded":false,"state":"loading"}]}"#
        XCTAssertTrue(try LocalModelProvider.decode(data(json), endpoint: e).isEmpty)
    }

    func testVisionHealthReadsOnlyLoadedModelsAndDeduplicatesKinds() throws {
        let e = LocalModelEndpoint.defaults.first { $0.port == 8080 }!
        XCTAssertEqual(e.url.path, "/health")
        let json = #"{"status":"healthy","loaded_model":"LiquidAI/LFM2.5-VL-3B-MLX-4bit","loaded_models":{"text_generation":{"model":"LiquidAI/LFM2.5-VL-3B-MLX-4bit","adapter":"style"},"speech":{"model":"mlx-community/VoxCPM2-8bit"},"embedding":{"model":null}},"data":[{"id":"krea/Krea-2-Turbo"}]}"#
        let models = try LocalModelProvider.decode(data(json), endpoint: e)
        XCTAssertEqual(models.map(\.name), ["LiquidAI/LFM2.5-VL-3B-MLX-4bit", "mlx-community/VoxCPM2-8bit"])
        XCTAssertTrue(models.allSatisfy { $0.activity == "로드됨" })
        XCTAssertTrue(try LocalModelProvider.decode(data(#"{"status":"healthy","loaded_model":null,"loaded_models":{}}"#), endpoint: e).isEmpty)
        let legacy = try LocalModelProvider.decode(data(#"{"loaded_model":"org/one-model"}"#), endpoint: e)
        XCTAssertEqual(legacy.map(\.name), ["org/one-model"])
        for invalid in [#"{"status":"healthy"}"#, #"{"loaded_model":123}"#, #"{"loaded_models":[]}"#] {
            XCTAssertThrowsError(try LocalModelProvider.decode(data(invalid), endpoint: e))
        }
    }

    func testDS4AliasesResolveToActualLoadedEngineName() throws {
        let e = LocalModelEndpoint(engine: "DS4", port: 8000, format: .openAI)
        let json = #"{"data":[{"id":"deepseek-v4-flash","owned_by":"ds4.c","name":"DeepSeek-V4-Flash"},{"id":"deepseek-v4-pro","owned_by":"ds4.c","name":"DeepSeek-V4-Flash"},{"id":"unverified"}]}"#
        XCTAssertEqual(try LocalModelProvider.decode(data(json), endpoint: e).map(\.name), ["DeepSeek-V4-Flash"])
    }

    private actor VisionHealthHTTP: LocalModelHTTPSource {
        private(set) var paths: [String] = []
        var loaded = true
        func unload() { loaded = false }
        func get(_ url: URL) async throws -> Data? {
            paths.append(url.path)
            if url.path == "/health" {
                return Data((loaded ? #"{"loaded_model":"org/active-model"}"# : #"{"loaded_model":null}"#).utf8)
            }
            return Data(#"{"data":[{"id":"cached-model"}]}"#.utf8)
        }
    }

    func testVisionSampleRemovesUnloadedModelWithoutFallingBackToCatalog() async {
        let http = VisionHealthHTTP()
        let endpoint = LocalModelEndpoint.defaults.first { $0.port == 8080 }!
        let provider = LocalModelProvider(source: http, endpoints: [endpoint], processes: NoLocalModelProcesses())
        let loaded = await provider.sample()
        XCTAssertEqual(loaded.value?.map(\.name), ["org/active-model"])
        await http.unload()
        let unloaded = await provider.sample()
        XCTAssertEqual(unloaded.status, .ok)
        XCTAssertEqual(unloaded.value, [])
        let paths = await http.paths
        XCTAssertEqual(paths, ["/health", "/health"])
    }

    func testOllamaUsesLoadedModelsEndpoint() throws {
        let e = LocalModelEndpoint(engine: "Ollama", port: 11434, format: .ollama)
        XCTAssertEqual(e.url.path, "/api/ps")
        let models = try LocalModelProvider.decode(data(#"{"models":[{"name":"qwen:32b"},{"model":"llama:8b"}]}"#), endpoint: e)
        XCTAssertEqual(models.map(\.name), ["llama:8b", "qwen:32b"])
        XCTAssertTrue(models.allSatisfy { $0.activity == "로드됨" })
    }

    func testComfyShowsOnlyRunningBaseModels() throws {
        let e = LocalModelEndpoint(engine: "ComfyUI", port: 8188, format: .comfyQueue)
        let json = #"{"queue_running":[[1,"id",{"a":{"class_type":"UNETLoader","inputs":{"unet_name":"ltx.safetensors"}},"b":{"class_type":"LoraLoader","inputs":{"lora_name":"style.safetensors"}},"c":{"class_type":"UpscaleModelLoader","inputs":{"model_name":"upscaler.safetensors"}},"d":{"class_type":"UNETLoader","inputs":{"unet_name":"ltx.safetensors"}}}]],"queue_pending":[[2,"later",{"e":{"inputs":{"ckpt_name":"pending.safetensors"}}}]]}"#
        let models = try LocalModelProvider.decode(data(json), endpoint: e)
        XCTAssertEqual(models.map(\.name), ["ltx.safetensors"])
        XCTAssertEqual(models[0].displayName, "ltx")
        XCTAssertEqual(models[0].activity, "실행 중")
        XCTAssertTrue(try LocalModelProvider.decode(data(#"{"queue_running":[],"queue_pending":[]}"#), endpoint: e).isEmpty)
    }

    func testMalformedPayloadIsFailureInsteadOfEmptyModels() {
        let e = LocalModelEndpoint(engine: "MLX", port: 11234, format: .openAI)
        XCTAssertThrowsError(try LocalModelProvider.decode(data(#"{"error":"busy"}"#), endpoint: e))
        XCTAssertThrowsError(try LocalModelProvider.decode(data("not json"), endpoint: e))
    }

    func testLongNamesFitAndMoveQuantizationToDetail() {
        let model = LocalModelInfo(name: "org/some-extremely-long-model-name-with-many-parts-v2-final-release-bf16.safetensors", engine: "ComfyUI", port: 8188, activity: "실행 중")
        XCTAssertEqual(model.shortName().count, 36)
        XCTAssertFalse(model.shortName().hasSuffix("bf16"))
        XCTAssertTrue(model.shortName().contains("…"))
        XCTAssertEqual(model.detail, "ComfyUI bf16 :8188 · 실행 중")
        XCTAssertTrue(model.name.hasSuffix(".safetensors"))
        let ltx = LocalModelInfo(name: "org/ltx-2.5-22b-distilled-transformer-bf16.safetensors", engine: "ComfyUI", port: 8188, activity: "실행 중")
        XCTAssertEqual(ltx.displayName, "ltx-2.5-22b-distilled-transformer")
    }

    func testFlashNextNameDropsEngineAndUncensoredWords() {
        let m = LocalModelInfo(name: "Qwen3.8-Flash-Next-Uncensored-MLX-Serve-4bit", engine: "MLX", port: 11234, activity: "제공")
        XCTAssertEqual(m.displayName, "Qwen3.8 Flash-Next")
        XCTAssertEqual(m.detail, "MLX 4bit :11234 · 제공")
        XCTAssertEqual(m.name, "Qwen3.8-Flash-Next-Uncensored-MLX-Serve-4bit")
    }

    func testOllamaNameUnchangedAndAllNoiseFallsBack() {
        let o = LocalModelInfo(name: "qwen:32b", engine: "Ollama", port: 11434, activity: "로드됨")
        XCTAssertEqual(o.displayName, "qwen:32b")
        XCTAssertEqual(o.detail, "Ollama :11434 · 로드됨")
        let n = LocalModelInfo(name: "MLX-4bit", engine: "MLX", port: 8081, activity: "제공")
        XCTAssertFalse(n.displayName.isEmpty)
        XCTAssertEqual(n.displayName, "MLX-4bit")
        let g = LocalModelInfo(name: "x/llama-3-8b-Q4_K_M.gguf", engine: "MLX", port: 8081, activity: "제공")
        XCTAssertEqual(g.displayName, "llama-3-8b")
        XCTAssertEqual(g.detail, "MLX Q4_K_M :8081 · 제공")
    }

    private struct StubHTTP: LocalModelHTTPSource {
        var fail = false
        func get(_ url: URL) async throws -> Data? {
            if fail { throw URLError(.timedOut) }
            return nil
        }
    }

    func testAbsentServersAndFailedRequestsRemainDistinct() async {
        let absent = await LocalModelProvider(source: StubHTTP(), processes: NoLocalModelProcesses()).sample()
        XCTAssertEqual(absent.status, .ok)
        XCTAssertEqual(absent.value, [])
        let failed = await LocalModelProvider(source: StubHTTP(fail: true), processes: NoLocalModelProcesses()).sample()
        guard case .failed = failed.status else { return XCTFail("실패를 모델 없음으로 위장하면 안 됨") }
        XCTAssertNil(failed.value)
    }

    // MARK: 두 번째 ComfyUI · 포트 없는 TTS 프로세스

    private static let voxArgv = [
        "/Users/mighty/Code/qwen3-tts-mlx/.venv/bin/python", "-c",
        "import mlx.core as mx\nfrom mlx_audio.tts.generate import generate_audio\ngenerate_audio()",
        "--model", "/Users/mighty/.cache/huggingface/hub/models--mlx-community--VoxCPM2-8bit/snapshots/d527a1b2c3d4e5f60718293a4b5c6d7e8f901234/",
        "--text=안녕하세요", "--lang_code", "ko",
    ]

    func testSecondComfyInstanceIsMonitored() {
        let e = LocalModelEndpoint.defaults.first { $0.port == 8190 }
        XCTAssertEqual(e?.engine, "ComfyUI")
        XCTAssertEqual(e?.url.absoluteString, "http://127.0.0.1:8190/queue")
        XCTAssertEqual(LocalModelEndpoint.defaults.filter { $0.port == 8188 }.count, 1)
        let json = #"{"queue_running":[[1,"id",{"a":{"class_type":"UnetLoaderGGUF","inputs":{"unet_name":"qwen-image-2.1-Q4_K_M.gguf"}}}]],"queue_pending":[]}"#
        let models = try? LocalModelProvider.decode(Data(json.utf8), endpoint: e!)
        XCTAssertEqual(models?.first?.name, "qwen-image-2.1-Q4_K_M.gguf")
        XCTAssertEqual(models?.first?.port, 8190)
    }

    func testMLXAudioArgvIsDetectedAsTTS() {
        let m = LocalModelProcessParser.audioModel(argv: Self.voxArgv)
        XCTAssertEqual(m?.name, "VoxCPM2-8bit")
        XCTAssertEqual(m?.displayName, "VoxCPM2")
        XCTAssertEqual(m?.detail, "TTS 8bit · 실행 중")
        XCTAssertEqual(m?.port, 0)
        XCTAssertEqual(m?.engine, "TTS")
    }

    func testNonAudioPythonAndModelFlagForms() {
        XCTAssertNil(LocalModelProcessParser.audioModel(argv: ["python3", "-c", "print(1)", "--model", "x"]))
        XCTAssertNil(LocalModelProcessParser.audioModel(argv: []))
        let eq = LocalModelProcessParser.audioModel(argv: ["python", "-m", "mlx_audio.tts.generate", "--model=/Users/x/.cache/huggingface/hub/models--mlx-community--Kokoro-82M-bf16/snapshots/abc1234def/"])
        XCTAssertEqual(eq?.name, "Kokoro-82M-bf16")
        let plain = LocalModelProcessParser.audioModel(argv: ["python", "-m", "mlx_audio.tts.generate", "--model", "/models/my-tts-4bit/"])
        XCTAssertEqual(plain?.name, "my-tts-4bit")
        let hashOnly = LocalModelProcessParser.audioModel(argv: ["python", "mlx_audio", "--model=/models/foo-tts/snapshots/0123456789abcdef"])
        XCTAssertEqual(hashOnly?.name, "foo-tts")
        let none = LocalModelProcessParser.audioModel(argv: ["python", "-m", "mlx_audio.tts.generate", "--text", "hi"])
        XCTAssertEqual(none?.name, "mlx_audio")
        XCTAssertEqual(none?.detail, "TTS · 실행 중")
        let dangling = LocalModelProcessParser.audioModel(argv: ["python", "mlx_audio", "--model"])
        XCTAssertEqual(dangling?.name, "mlx_audio")
    }

    func testProcArgsBufferParsingStaysInBounds() {
        func buf(argc: Int32, exec: String, argv: [String], env: [String] = [], padding: Int = 3) -> [UInt8] {
            var b = withUnsafeBytes(of: argc) { Array($0) }
            b += Array(exec.utf8) + [0] + [UInt8](repeating: 0, count: padding)
            for a in argv + env { b += Array(a.utf8) + [0] }
            return b
        }
        XCTAssertEqual(LocalModelProcessParser.parseProcArgs(buf(argc: 3, exec: "/bin/python", argv: ["python", "-c", "x y"], env: ["A=1"])), ["python", "-c", "x y"])
        XCTAssertNil(LocalModelProcessParser.parseProcArgs(buf(argc: 5, exec: "/bin/python", argv: ["python", "-c"])), "argc 가 실제보다 크면 거부")
        XCTAssertNil(LocalModelProcessParser.parseProcArgs([1, 0]))
        XCTAssertNil(LocalModelProcessParser.parseProcArgs([]))
        XCTAssertNil(LocalModelProcessParser.parseProcArgs(buf(argc: 0, exec: "/bin/python", argv: [])))
        XCTAssertNil(LocalModelProcessParser.parseProcArgs(buf(argc: -1, exec: "/bin/python", argv: ["a"])))
        XCTAssertNil(LocalModelProcessParser.parseProcArgs(Array(buf(argc: 1, exec: "/bin/python", argv: ["python"]).prefix(8))), "exec 경로 중간에서 잘림")
        XCTAssertEqual(LocalModelProcessParser.parseProcArgs(Array(buf(argc: 1, exec: "/bin/python", argv: ["python"]).dropLast())), ["python"], "마지막 NUL 이 없어도 범위 안")
    }

    func testLibprocSourceReadsArgvOfRealPythonProcess() throws {
        let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let python else { throw XCTSkip("python3 없음") }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: python)
        child.arguments = ["-c", "import time; time.sleep(20)  # mlx_audio probe", "--model=/tmp/models--org--ProbeModel-4bit/snapshots/abcdef1"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        var found: LocalModelInfo?
        for _ in 0..<40 where found == nil {
            found = LibprocArgvSource().candidateArguments().compactMap(LocalModelProcessParser.audioModel(argv:)).first { $0.name == "ProbeModel-4bit" }
            if found == nil { Thread.sleep(forTimeInterval: 0.1) }
        }
        XCTAssertEqual(found?.detail, "TTS 4bit · 실행 중")
    }

    private struct FakeProcesses: LocalModelProcessSource {
        var argvs: [[String]]
        func candidateArguments() -> [[String]] { argvs }
    }

    func testSampleMergesProcessesWithServersAndDedupes() async {
        let p = LocalModelProvider(source: StubHTTP(), processes: FakeProcesses(argvs: [Self.voxArgv, Self.voxArgv, ["python", "-c", "print(1)"]]))
        let r = await p.sample()
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.value?.map(\.name), ["VoxCPM2-8bit"])
    }

    // MARK: 포트 없는 이미지·영상 생성 스크립트

    private static let minimaxArgv = [
        "/opt/homebrew/Cellar/python@3.12/3.12.8/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python",
        "/Users/mighty/Code/minimax-h3-mlx/scripts/generate.py", "Hand-drawn anime fox running",
        "-o", "/Users/mighty/ComfyUI-Shared/output/fox.mp4",
        "-t", "/Users/mighty/Code/minimax-h3-mlx/models/MiniMax-H3-MLX-8bit",
    ]

    func testMiniMaxGeneratorArgvIsDetected() {
        let m = LocalModelProcessParser.generatorModel(argv: Self.minimaxArgv)
        XCTAssertEqual(m, LocalModelInfo(name: "MiniMax-H3", engine: "MLX", port: 0, activity: "생성 중"))
        XCTAssertNil(LocalModelProcessParser.audioModel(argv: Self.minimaxArgv))
    }

    func testMfluxAndIrisGeneratorArgvAreDetected() {
        let mflux = LocalModelProcessParser.generatorModel(argv: ["/usr/bin/python3", "/Users/mighty/.venv/bin/mflux-generate", "--prompt", "cat"])
        XCTAssertEqual(mflux?.name, "mflux")
        XCTAssertEqual(mflux?.engine, "MLX")
        XCTAssertEqual(mflux?.port, 0)
        XCTAssertEqual(mflux?.activity, "생성 중")
        let iris = LocalModelProcessParser.generatorModel(argv: ["python", "/Users/mighty/Code/iris-3b-turbo/scripts/sample.py", "--prompt", "cat"])
        XCTAssertEqual(iris?.name, "Iris-3B")
        XCTAssertEqual(iris?.engine, "Torch")
        XCTAssertEqual(iris?.port, 0)
        XCTAssertEqual(iris?.activity, "생성 중")
    }

    func testUnrelatedPythonIsNotGenerator() {
        XCTAssertNil(LocalModelProcessParser.generatorModel(argv: ["python3", "-m", "http.server"]))
        XCTAssertNil(LocalModelProcessParser.generatorModel(argv: []))
        // 프롬프트에만 스크립트 이름이 섞인 경우
        XCTAssertNil(LocalModelProcessParser.generatorModel(argv: ["python3", "/Users/mighty/Code/other/run.py", "explain generate.py and sample.py in minimax-h3-mlx and iris-3b-turbo"]))
        XCTAssertNil(LocalModelProcessParser.generatorModel(argv: ["python3", "/Users/mighty/Code/other/run.py", "about generate.py in minimax-h3-mlx scripts/generate.py now"]))
        // 다른 프로젝트의 generate.py / sample.py
        XCTAssertNil(LocalModelProcessParser.generatorModel(argv: ["python3", "/Users/mighty/Code/other/scripts/generate.py"]))
        XCTAssertNil(LocalModelProcessParser.generatorModel(argv: ["python3", "/Users/mighty/Code/other/sample.py"]))
    }

    func testSampleCollectsGeneratorsAlongsideAudio() async {
        let p = LocalModelProvider(source: StubHTTP(), processes: FakeProcesses(argvs: [Self.voxArgv, Self.minimaxArgv, Self.minimaxArgv, ["python3", "-m", "http.server"]]))
        let r = await p.sample()
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(Set(r.value?.map(\.name) ?? []), ["VoxCPM2-8bit", "MiniMax-H3"])
        XCTAssertEqual(r.value?.count, 2)
    }

    private struct ServerHTTP: LocalModelHTTPSource {
        func get(_ url: URL) async throws -> Data? {
            url.port == 11234 ? Data(#"{"data":[{"id":"org/Test-Model","loaded":true}]}"#.utf8) : nil
        }
    }

    func testProcessModelsSortAfterServers() async {
        let p = LocalModelProvider(source: ServerHTTP(), processes: FakeProcesses(argvs: [Self.voxArgv]))
        let r = await p.sample()
        XCTAssertEqual(r.value?.map(\.name), ["org/Test-Model", "VoxCPM2-8bit"])
    }
}

final class MemoryRankingTests: XCTestCase {
    func testMemoryRanksAheadOfCPUAndIncludesNewProcesses() {
        let samples = [
            ProcessSample(pid: 1, name: "Busy", cpuTimeNs: 8_000_000_000, residentBytes: 10),
            ProcessSample(pid: 2, name: "Idle", cpuTimeNs: 0, residentBytes: 100),
            ProcessSample(pid: 3, name: "Idle", cpuTimeNs: 0, residentBytes: 150),
            ProcessSample(pid: 4, name: "New", cpuTimeNs: 9_000_000_000, residentBytes: 300),
        ]
        let top = ProcessMath.topUsage(prev: [1: 0, 2: 0, 3: 0], cur: samples, dtSeconds: 1, limit: 2)
        XCTAssertEqual(top.map(\.name), ["New", "Idle"])
        XCTAssertEqual(top[0].cpuPercent, 0)
        XCTAssertEqual(top[1].residentBytes, 250)
        XCTAssertEqual(top[1].count, 2)
    }

    private struct FixedSource: ProcessSource {
        func readAll() -> [ProcessSample]? {
            [ProcessSample(pid: 1, name: "Large", cpuTimeNs: 100_000, residentBytes: 500)]
        }
    }

    func testFirstSampleAndLongGapsStillReportMemory() {
        let provider = ProcessProvider(source: FixedSource())
        for ns: UInt64 in [1, 1_000_000_001, 99_000_000_001] {
            let reading = provider.sample(now: Date(), nowNs: ns)
            XCTAssertEqual(reading.status, .ok)
            XCTAssertEqual(reading.unit, "bytes")
            XCTAssertEqual(reading.value?.first?.residentBytes, 500)
            XCTAssertEqual(reading.value?.first?.cpuPercent, 0)
        }
    }
}
