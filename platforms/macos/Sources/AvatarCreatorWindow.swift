import AppKit
import WebKit

/// 云端「图片 → VRM」生成窗口（B1：VTubeMe）。
///
/// 说明：VRM 的真·图片建模没有免费可自动化 API（Ready Player Me 本网络不可达、且只出 GLB）。
/// 因此本窗口内嵌 VTubeMe 的图片生成页，由用户在网页内生成并下载 VRM，回到这里点
/// 「导入 VRM…」装成桌宠形象包。**图片会经第三方处理**——这是用户显式选择的云端路线，
/// 与 ADR-0009 的本地/授权边界说明一致。
final class AvatarCreatorWindowController: NSWindowController, WKNavigationDelegate {
    static let shared = AvatarCreatorWindowController()
    private static let creatorURL = URL(string: "https://vtubeme.com/create/picture")!

    private let webView: WKWebView
    private let statusLabel = NSTextField(labelWithString: "在网页里生成并下载 VRM（.vrm），再点右下角「导入 VRM…」")

    private init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        // 伪装成 Safari，避免被站点判定为非浏览器
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "图片生成 VRM（VTubeMe 云端）"
        window.center()
        super.init(window: window)
        webView.navigationDelegate = self

        let browser = NSButton(title: "在浏览器打开", target: self, action: #selector(openInBrowser))
        let importButton = NSButton(title: "导入 VRM…", target: self, action: #selector(importVRM))
        importButton.keyEquivalent = "\r"
        let bar = NSStackView(views: [statusLabel, NSView(), browser, importButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let root = NSStackView(views: [webView, bar])
        root.orientation = .vertical
        root.spacing = 0
        root.distribution = .fill
        bar.setContentHuggingPriority(.required, for: .vertical)
        webView.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                root.topAnchor.constraint(equalTo: content.topAnchor),
                root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if webView.url == nil {
            webView.load(URLRequest(url: Self.creatorURL))
        }
    }

    @objc private func openInBrowser() {
        NSWorkspace.shared.open(Self.creatorURL)
    }

    @objc private func importVRM() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择刚下载的 VRM 文件（.vrm）"
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.init(filenameExtension: "vrm") ?? .data]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PetImporter.importVRM(from: url, packId: "vrm-cloud", name: "云端生成 VRM")
            PetWindowController.activePackId = "vrm-cloud"
            if !PetWindowController.isEnabled {
                PetWindowController.setEnabled(true)
            }
            statusLabel.stringValue = "已导入并切换：\(url.lastPathComponent)"
            PetWindowController.shared.showToast("已导入并切换：\(url.lastPathComponent)", duration: 4)
        } catch {
            statusLabel.stringValue = "导入失败：\(error.localizedDescription)"
            PetWindowController.shared.showToast("导入失败：\(error.localizedDescription)", duration: 6)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        statusLabel.stringValue = "生成完成后下载 VRM，再点「导入 VRM…」；若页面加载异常请点「在浏览器打开」"
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        statusLabel.stringValue = "页面加载失败：\(error.localizedDescription)（可点「在浏览器打开」）"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        statusLabel.stringValue = "页面加载失败：\(error.localizedDescription)（可点「在浏览器打开」）"
    }
}
