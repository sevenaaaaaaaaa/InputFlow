import AppKit
import CryptoKit
import Foundation

/// 模型目录条目（与 `crates/ai` 的 JSON 字段一一对应）。
struct AIModelInfo: Codable, Identifiable {
    let id: String
    let name: String
    let kinds: [String]
    let params: String
    let quant: String
    let file: String
    let url: String
    let sizeBytes: UInt64
    let sha256: String
    let ramMb: Int
    let license: String
    let languages: [String]
    let note: String

    func supports(_ kind: String) -> Bool { kinds.contains(kind) }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }

    var quantText: String { "\(params) · \(quant)" }
}

struct AIRecommendation: Codable {
    let kind: String
    let modelId: String?
    let ramMb: Int
    let level: String
    let levelLabel: String
}

struct AIRecommendationSet: Codable {
    let totalRamMb: Int
    let recommendations: [AIRecommendation]

    func level(for kind: String) -> String {
        recommendations.first { $0.kind == kind }?.level ?? "heavy"
    }

    func levelLabel(for kind: String) -> String {
        recommendations.first { $0.kind == kind }?.levelLabel ?? "不推荐"
    }

    func recommendedId(for kind: String) -> String? {
        recommendations.first { $0.kind == kind }?.modelId
    }
}

/// 模型下载/存储/选择状态。下载仅在用户点击后发生，落盘前校验 sha256。
final class AIModelStore: NSObject {
    static let shared = AIModelStore()

    let catalog: [AIModelInfo]
    let recommendation: AIRecommendationSet

    /// 下载进度回调（模型 id, 0...1）
    var onProgress: ((String, Double) -> Void)?
    /// 下载结束回调（模型 id, 错误信息）
    var onFinish: ((String, String?) -> Void)?
    /// 状态变化（安装/删除）
    var onStateChange: (() -> Void)?

    private var progress: [String: Double] = [:]
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        catalog = InputFlowEngine.aiCatalog()
        let ramMb = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        recommendation = InputFlowEngine.aiRecommend(totalRamMb: ramMb)
        super.init()
    }

    var totalRamText: String {
        ByteCountFormatter.string(fromByteCount: Int64(recommendation.totalRamMb) * 1024 * 1024, countStyle: .memory)
    }

    // MARK: - 磁盘

    var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InputFlow/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func path(for model: AIModelInfo) -> URL {
        modelsDirectory.appendingPathComponent(model.id, isDirectory: true).appendingPathComponent(model.file)
    }

    func isInstalled(_ model: AIModelInfo) -> Bool {
        let url = path(for: model)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return false }
        return size.uint64Value == model.sizeBytes
    }

    func isDownloading(_ model: AIModelInfo) -> Bool { tasks[model.id] != nil }

    func downloadProgress(for model: AIModelInfo) -> Double { progress[model.id] ?? 0 }

    func diskUsage() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: modelsDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    // MARK: - 下载

    func download(_ model: AIModelInfo) {
        guard tasks[model.id] == nil, let url = URL(string: model.url) else { return }
        progress[model.id] = 0
        let task = session.downloadTask(with: url)
        task.taskDescription = model.id
        tasks[model.id] = task
        task.resume()
        onStateChange?()
    }

    func cancel(_ model: AIModelInfo) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        progress[model.id] = nil
        onStateChange?()
    }

    func delete(_ model: AIModelInfo) {
        try? FileManager.default.removeItem(at: path(for: model).deletingLastPathComponent())
        onStateChange?()
    }

    private func finishDownload(id: String, temporaryURL: URL, error: String?) {
        defer {
            tasks[id] = nil
            progress[id] = nil
            DispatchQueue.main.async { self.onStateChange?() }
        }
        guard error == nil,
              let model = catalog.first(where: { $0.id == id }) else {
            DispatchQueue.main.async { self.onFinish?(id, error) }
            return
        }
        let destination = path(for: model)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            let digest = try Self.sha256(of: destination)
            guard digest == model.sha256.lowercased() else {
                try? FileManager.default.removeItem(at: destination)
                throw NSError(domain: "InputFlow.AI", code: 1, userInfo: [NSLocalizedDescriptionKey: "sha256 校验失败，已删除下载文件"])
            }
            DispatchQueue.main.async { self.onFinish?(id, nil) }
        } catch {
            DispatchQueue.main.async { self.onFinish?(id, error.localizedDescription) }
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 启用状态（UserDefaults）

    static func selectedModelId(for kind: String) -> String? {
        UserDefaults.standard.string(forKey: "InputFlowAIModel.\(kind)")
    }

    static func setSelectedModelId(_ id: String?, for kind: String) {
        if let id {
            UserDefaults.standard.set(id, forKey: "InputFlowAIModel.\(kind)")
        } else {
            UserDefaults.standard.removeObject(forKey: "InputFlowAIModel.\(kind)")
        }
        NotificationCenter.default.post(name: .inputFlowAIChanged, object: nil)
    }

    static func enabledModel(for kind: String) -> AIModelInfo? {
        guard let id = selectedModelId(for: kind) else { return nil }
        return AIModelStore.shared.catalog.first { $0.id == id && $0.supports(kind) }
    }
}

extension Notification.Name {
    static let inputFlowAIChanged = Notification.Name("InputFlowAIChanged")
}

extension AIModelStore: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progress[id] = value
        DispatchQueue.main.async { self.onProgress?(id, value) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = downloadTask.taskDescription else { return }
        // 临时文件在本回调返回后即被删除，先搬走再校验。
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("inputflow-\(id)-\(UUID().uuidString)")
        try? FileManager.default.moveItem(at: location, to: staged)
        finishDownload(id: id, temporaryURL: staged, error: nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription, let error else { return }
        if (error as NSError).code != NSURLErrorCancelled {
            finishDownload(id: id, temporaryURL: URL(fileURLWithPath: "/nonexistent"), error: error.localizedDescription)
        }
    }
}
