import AppKit
import Foundation

/// 同声传译运行时：llama.cpp 的 `llama-server` 独立进程 + 127.0.0.1 回环 HTTP。
///
/// ADR-0004 边界：
/// - 运行时不由 InputFlow 下载（用户自行 `brew install llama.cpp`），这里只做检测与引导；
/// - 模型走 `AIModelStore`（点击下载 + sha256 校验），未安装时拒绝启动；
/// - 只连接回环地址：原文与译文不离开设备，没有遥测、没有外部请求。
final class TranslateClient {
    static let shared = TranslateClient()

    enum TranslateError: LocalizedError {
        case runtimeMissing
        case modelMissing
        case serverFailed(String)
        case badResponse
        case timeout

        var errorDescription: String? {
            switch self {
            case .runtimeMissing: return "未检测到 llama.cpp 运行时（终端执行 brew install llama.cpp）"
            case .modelMissing: return "未安装翻译模型（菜单「AI 增强」下载）"
            case .serverFailed(let detail): return "llama-server 启动失败：\(detail)"
            case .badResponse: return "翻译响应无法解析"
            case .timeout: return "翻译请求超时"
            }
        }
    }

    private var process: Process?
    private var port: Int?
    private var stderrTail = ""
    private var starting = false
    private var startWaiters: [(Bool) -> Void] = []
    private var queue: [(body: Data, completion: (Result<String, Error>) -> Void)] = []
    private var inflight = false
    private static var cleanupInstalled = false

    // MARK: - 探测

    /// 查找 llama-server：环境变量 → 常见路径 → PATH。
    static func findRuntime() -> String? {
        if let p = ProcessInfo.processInfo.environment["INPUTFLOW_LLAMA_SERVER"],
           FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        for p in ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let p = "\(dir)/llama-server"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// 可用的翻译模型路径：优先已启用的 translate 模型，否则自动启用第一个已安装的。
    static func translateModelPath() -> String? {
        let store = AIModelStore.shared
        if let enabled = AIModelStore.enabledModel(for: "translate"), store.isInstalled(enabled) {
            return store.path(for: enabled).path
        }
        if let model = store.catalog.first(where: { $0.supports("translate") && store.isInstalled($0) }) {
            AIModelStore.setSelectedModelId(model.id, for: "translate")
            return store.path(for: model).path
        }
        return nil
    }

    var isRunning: Bool { process?.isRunning == true && port != nil }

    // MARK: - 服务生命周期

    /// 预热：异步拉起服务（失败静默，真实请求时会再报错）。
    func warmup() {
        ensureServer { _ in }
    }

    private func ensureServer(completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            if self.isRunning, self.process != nil {
                completion(true)
                return
            }
            self.startWaiters.append(completion)
            guard !self.starting else { return }
            self.startServerLocked()
        }
    }

    private func startServerLocked() {
        starting = true
        guard let bin = Self.findRuntime() else { flushStarters(false, error: TranslateError.runtimeMissing); return }
        guard let model = Self.translateModelPath() else { flushStarters(false, error: TranslateError.modelMissing); return }
        Self.installCleanup()

        let chosen = Int.random(in: 20_480...45_000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = ["-m", model, "--host", "127.0.0.1", "--port", "\(chosen)"]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        stderrTail = ""

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            let text = String(data: data, encoding: .utf8) ?? ""
            self.stderrTail = (self.stderrTail + text)
            if self.stderrTail.count > 4000 {
                self.stderrTail = String(self.stderrTail.suffix(4000))
            }
        }

        do {
            try process.run()
        } catch {
            flushStarters(false, error: TranslateError.serverFailed(error.localizedDescription))
            return
        }
        self.process = process
        self.port = chosen
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.process === proc else { return }
                let failed = self.starting
                self.process = nil
                self.port = nil
                if failed {
                    let tail = self.stderrTail.split(separator: "\n").suffix(3).joined(separator: " | ")
                    self.flushStarters(false, error: TranslateError.serverFailed(tail.isEmpty ? "进程退出(\(proc.terminationStatus))" : tail))
                }
            }
        }

        pollHealth(tries: 160) { [weak self] ok in
            guard let self else { return }
            self.starting = false
            if !ok {
                self.stop()
                self.flushStarters(false, error: TranslateError.serverFailed(
                    self.stderrTail.split(separator: "\n").suffix(3).joined(separator: " | ")
                ))
            } else {
                self.flushStarters(true, error: nil)
                self.pump()
            }
        }
    }

    /// 轮询 `/health`：绑定成功但模型加载中会先拒绝/503，就绪后返回 200。
    private func pollHealth(tries: Int, completion: @escaping (Bool) -> Void) {
        guard let port else { completion(false); return }
        guard tries > 0 else { completion(false); return }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                guard let self, self.starting else {
                    completion(response != nil)
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    completion(true)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        self.pollHealth(tries: tries - 1, completion: completion)
                    }
                }
            }
        }.resume()
    }

    private func flushStarters(_ ok: Bool, error: Error?) {
        let waiters = startWaiters
        startWaiters = []
        starting = false
        waiters.forEach { $0(ok) }
        _ = error
    }

    /// 停止服务（释放模型内存）。进程内退出时也会尽力调用（atexit）。
    func stop() {
        DispatchQueue.main.async { self.stopLocked() }
    }

    private func stopLocked() {
        let pending = queue
        queue = []
        inflight = false
        pending.forEach { $0.completion(.failure(TranslateError.serverFailed("服务已停止"))) }
        port = nil
        if let process {
            self.process = nil
            process.terminationHandler = nil
            // 不改已 launch 的 task 配置属性（会抛 "task already launched"）
            (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
                }
            }
        }
        starting = false
        let waiters = startWaiters
        startWaiters = []
        waiters.forEach { $0(false) }
    }

    private static func installCleanup() {
        guard !cleanupInstalled else { return }
        cleanupInstalled = true
        atexit {
            // 尽力清理：IME 进程退出时杀掉 llama-server，避免孤儿进程占内存。
            TranslateClient.shared.forceStopSync()
        }
    }

    private func forceStopSync() {
        if let process {
            process.terminationHandler = nil
            (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
                }
            }
        }
        process = nil
        port = nil
    }

    // MARK: - 翻译请求（串行队列，保序）

    func translate(_ text: String, target: String, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.main.async {
            guard Self.findRuntime() != nil else {
                completion(.failure(TranslateError.runtimeMissing)); return
            }
            guard Self.translateModelPath() != nil else {
                completion(.failure(TranslateError.modelMissing)); return
            }
            let language = target == "ja" ? "Japanese" : "English"
            let payload: [String: Any] = [
                "model": "inputflow",
                "messages": [
                    ["role": "system", "content":
                        "Translate the Chinese input completely into natural \(language). Never omit, summarize, or shorten any part. Output ONLY the \(language) translation, nothing else."],
                    ["role": "user", "content": text],
                ],
                "temperature": 0.2,
                "max_tokens": 400,
                "stream": false,
            ]
            guard JSONSerialization.isValidJSONObject(payload),
                  let body = try? JSONSerialization.data(withJSONObject: payload) else {
                completion(.failure(TranslateError.badResponse)); return
            }
            self.queue.append((body, completion))
            self.ensureServer { ok in
                if !ok {
                    let failed = self.queue
                    self.queue = []
                    failed.forEach { $0.completion(.failure(TranslateError.serverFailed("运行时/模型不可用"))) }
                    return
                }
                self.pump()
            }
        }
    }

    private func pump() {
        guard !inflight, !queue.isEmpty, let port,
              process?.isRunning == true else { return }
        inflight = true
        let next = queue.removeFirst()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = next.body
        let started = Date()
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inflight = false
                defer {
                    if self.process != nil { self.pump() }
                }
                if let error {
                    next.completion(.failure(error)); return
                }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    next.completion(.failure(TranslateError.serverFailed("HTTP \(http.statusCode): \(body.prefix(200))")))
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    next.completion(.failure(TranslateError.badResponse)); return
                }
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                next.completion(.success(trimmed))
                _ = started
            }
        }.resume()
    }
}
