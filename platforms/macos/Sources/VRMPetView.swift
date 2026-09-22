import AppKit
import WebKit

/// VRM 桌宠运行时：把 app 内置的 three.js/three-vrm 运行时复制到用户目录，
/// 并按形象包准备模型文件（WebKit 只能读一个目录树，所以统一放运行时目录）。
enum PetRuntimeStore {
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InputFlow/pet-runtime", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static var bundledDir: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("PetRuntime", isDirectory: true)
    }

    private static func marker(_ dir: URL) -> String? {
        try? String(contentsOf: dir.appendingPathComponent("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 确保运行时与 app 内置版本一致（VERSION 不同则整目录更新）。
    @discardableResult
    static func ensure() -> URL {
        let fm = FileManager.default
        guard let bundled = bundledDir, fm.fileExists(atPath: bundled.path) else { return dir }
        if marker(dir) != marker(bundled) || !fm.fileExists(atPath: dir.appendingPathComponent("pet.html").path) {
            try? fm.removeItem(at: dir)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if let items = try? fm.contentsOfDirectory(at: bundled, includingPropertiesForKeys: [.isDirectoryKey]) {
                for item in items {
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: item.path, isDirectory: &isDir)
                    if isDir.boolValue {
                        try? fm.copyItem(at: item, to: dir.appendingPathComponent(item.lastPathComponent))
                    } else {
                        try? fm.copyItem(at: item, to: dir.appendingPathComponent(item.lastPathComponent))
                    }
                }
            }
        }
        return dir
    }

    /// 为形象包准备模型，返回相对运行时目录的路径（供 pet.html?model= 使用）。
    static func modelPath(for packId: String, entry: String?) -> String? {
        let fm = FileManager.default
        let runtime = ensure()
        let models = runtime.appendingPathComponent("models", isDirectory: true)
        try? fm.createDirectory(at: models, withIntermediateDirectories: true)
        let destination = models.appendingPathComponent("\(packId).vrm")
        let source: URL?
        if let entry, !entry.isEmpty {
            source = PluginStore.pluginsDir
                .appendingPathComponent(packId, isDirectory: true)
                .appendingPathComponent(entry)
        } else {
            source = runtime.appendingPathComponent("sample.vrm")   // 内置样例模型
        }
        guard let source, fm.fileExists(atPath: source.path) else { return nil }
        // 源比目标新才复制
        let srcDate = (try? fm.attributesOfItem(atPath: source.path)[.modificationDate] as? Date) ?? nil
        let dstDate = (try? fm.attributesOfItem(atPath: destination.path)[.modificationDate] as? Date) ?? nil
        if dstDate == nil || (srcDate != nil && dstDate! < srcDate!) {
            try? fm.removeItem(at: destination)
            try? fm.copyItem(at: source, to: destination)
        }
        return "models/\(packId).vrm"
    }
}

/// 桌宠 VRM 视图：透明 WKWebView + three-vrm 渲染。
final class VRMPetView: WKWebView, WKScriptMessageHandler, WKNavigationDelegate {
    var onReady: (() -> Void)?
    var onError: ((String) -> Void)?

    private var pendingState = "idle"
    private let runtimeDir: URL

    init(frame: NSRect, modelPath: String, framing: String = "full", zoom: Double = 1.0) {
        runtimeDir = PetRuntimeStore.ensure()
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        // file:// 下允许加载 ES module 与本地资源（three.js/three-vrm 必需）
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        config.mediaTypesRequiringUserActionForPlayback = []
        let controller = WKUserContentController()
        config.userContentController = controller
        super.init(frame: frame, configuration: config)
        controller.add(self, name: "pet")

        setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            underPageBackgroundColor = .clear
        }
        navigationDelegate = self
        setValue(false, forKey: "allowsMagnification")

        let page = runtimeDir.appendingPathComponent("pet.html")
        let url = URL(string: "\(page.absoluteString)?model=\(modelPath)&framing=\(framing)&zoom=\(zoom)") ?? page
        loadFileURL(url, allowingReadAccessTo: runtimeDir)
    }

    required init?(coder: NSCoder) { nil }

    /// 鼠标事件穿透给父视图（桌宠的点击/拖动/悬停都靠父视图处理）
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setState(_ state: String) {
        pendingState = state
        evaluateJavaScript("window.petSetState && window.petSetState('\(state)')") { _, _ in }
    }

    func setGaze(dx: Double, dy: Double) {
        evaluateJavaScript("window.petSetGaze && window.petSetGaze(\(dx), \(dy))") { _, _ in }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["ready"] as? Bool == true {
            setState(pendingState)
            onReady?()
        }
        if let error = body["error"] as? String {
            onError?(error)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        setState(pendingState)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onError?("导航失败: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onError?("页面加载失败: \(error.localizedDescription)")
    }

    /// 抓取当前 WebGL 画面（canvas.toDataURL），返回 PNG 数据。
    func capturePNG(_ completion: @escaping (Data?) -> Void) {
        evaluateJavaScript("window.petCapture && window.petCapture()") { value, _ in
            guard
                let string = value as? String,
                let comma = string.firstIndex(of: ","),
                let data = Data(base64Encoded: String(string[string.index(after: comma)...]))
            else {
                completion(nil)
                return
            }
            completion(data)
        }
    }

    /// 开发用：取回页面内状态（是否 ready / 报错信息 / 绘制统计）。
    func debugState(_ completion: @escaping (String) -> Void) {
        evaluateJavaScript("JSON.stringify({ready: !!window.__petReady, err: window.__petErr || '', info: (window.petInfo ? JSON.parse(window.petInfo()) : null)})") { value, error in
            if let error {
                completion("evaluate-error: \(error.localizedDescription)")
            } else {
                completion(String(describing: value ?? "nil"))
            }
        }
    }
}
