import AppKit

/// 「AI 增强」设置窗：内置统计模型状态 + 可下载小模型的选择、下载与启停。
///
/// 隐私边界（与 ADR-0004 一致）：没有云 API；下载只在用户点击后发生；
/// 下载完成后必须通过 sha256 校验；语音模型仅本地运行。
final class AISettingsWindowController: NSWindowController {
    static let shared = AISettingsWindowController()

    private let store = AIModelStore.shared
    private let contentStack = NSStackView()
    private var statusLabel = NSTextField(labelWithString: "")

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 660),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "InputFlow · AI 增强"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildUI()
    }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - UI

    private func buildUI() {
        guard let window else { return }
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 14
        contentStack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        scroll.documentView = documentView

        window.contentView = scroll
        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
        refresh()
    }

    private func refresh() {
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let title = NSTextField(labelWithString: "本地 AI 增强")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        contentStack.addArrangedSubview(title)

        statusLabel = NSTextField(labelWithString: statusText())
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        contentStack.addArrangedSubview(statusLabel)

        let privacy = NSTextField(wrappingLabelWithString:
            "全部在本机运行：没有云 API、没有遥测。模型下载只在你点击后通过 HTTPS 直连模型仓库，"
            + "并用 sha256 校验完整性；语音识别强制端上执行，不会回退云端。")
        privacy.font = .systemFont(ofSize: 12)
        privacy.textColor = .secondaryLabelColor
        privacy.preferredMaxLayoutWidth = 560
        contentStack.addArrangedSubview(privacy)

        contentStack.addArrangedSubview(separator())
        addBuiltinSection()
        contentStack.addArrangedSubview(separator())
        addDownloadSection()

        let footnote = NSTextField(wrappingLabelWithString:
            "神经模型推理运行时（llama.cpp / whisper.cpp）将在下一里程碑接入；"
            + "接入前，下载的模型会安全存放在本地，内置统计模型已默认生效。")
        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .tertiaryLabelColor
        footnote.preferredMaxLayoutWidth = 560
        contentStack.addArrangedSubview(footnote)

        store.onStateChange = { [weak self] in self?.refresh() }
    }

    private func addBuiltinSection() {
        contentStack.addArrangedSubview(sectionTitle("内置能力（零下载，默认开启）"))

        let stat = NSStackView()
        stat.orientation = .vertical
        stat.alignment = .leading
        stat.spacing = 2
        let name = NSTextField(labelWithString: "统计语言模型 · 用户词 + 上下词预测")
        name.font = .systemFont(ofSize: 13, weight: .medium)
        let detail = NSTextField(labelWithString: "内存 < 1 MB · 随输入自动学习，无需任何配置")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        stat.addArrangedSubview(name)
        stat.addArrangedSubview(detail)

        let row = NSStackView(views: [stat, NSView(), badge("已启用", color: .systemGreen)])
        row.orientation = .horizontal
        row.alignment = .centerY
        contentStack.addArrangedSubview(row)
    }

    private func addDownloadSection() {
        contentStack.addArrangedSubview(sectionTitle("可下载模型（本地运行，按内存推荐）"))

        for model in store.catalog {
            contentStack.addArrangedSubview(modelRow(model))
        }
    }

    private func modelRow(_ model: AIModelInfo) -> NSView {
        let kind = model.kinds.first ?? "assist"
        let level = store.recommendation.level(for: kind)
        let levelLabel = store.recommendation.levelLabel(for: kind)

        let name = NSTextField(labelWithString: "\(model.name)  ·  \(model.quantText)")
        name.font = .systemFont(ofSize: 13, weight: .medium)

        let meta = NSTextField(labelWithString:
            "\(model.sizeText) 磁盘 · 约 \(model.ramMb) MB 内存 · \(model.license) · \(model.note)")
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingTail

        let subtitle = NSStackView(views: [name, meta])
        subtitle.orientation = .vertical
        subtitle.alignment = .leading
        subtitle.spacing = 2

        let kinds = NSTextField(labelWithString: model.kinds.map(kindLabel).joined(separator: " / "))
        kinds.font = .systemFont(ofSize: 10)
        kinds.textColor = .tertiaryLabelColor

        let right = NSStackView()
        right.orientation = .horizontal
        right.spacing = 8
        right.alignment = .centerY

        if store.isDownloading(model) {
            let progress = NSProgressIndicator()
            progress.style = .bar
            progress.isIndeterminate = false
            progress.minValue = 0
            progress.maxValue = 1
            progress.doubleValue = store.downloadProgress(for: model)
            progress.widthAnchor.constraint(equalToConstant: 90).isActive = true
            let cancel = NSButton(title: "取消", target: self, action: #selector(cancelDownload(_:)))
            cancel.identifier = NSUserInterfaceItemIdentifier(model.id)
            right.addArrangedSubview(progress)
            right.addArrangedSubview(cancel)
        } else if store.isInstalled(model) {
            let enabled = AIModelStore.selectedModelId(for: kind) == model.id
            let enable = NSButton(title: enabled ? "已启用" : "启用", target: self, action: #selector(toggleEnable(_:)))
            enable.identifier = NSUserInterfaceItemIdentifier(model.id)
            enable.bezelStyle = .rounded
            let delete = NSButton(title: "删除", target: self, action: #selector(deleteModel(_:)))
            delete.identifier = NSUserInterfaceItemIdentifier(model.id)
            delete.bezelStyle = .rounded
            right.addArrangedSubview(enable)
            right.addArrangedSubview(delete)
        } else {
            let button = NSButton(title: "下载", target: self, action: #selector(download(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(model.id)
            button.bezelStyle = .rounded
            right.addArrangedSubview(button)
        }

        let badgeView = badge(levelLabel, color: badgeColor(level))
        let row = NSStackView(views: [subtitle, NSView(), kinds, badgeView, right])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.distribution = .fill
        row.widthAnchor.constraint(equalToConstant: 576).isActive = true
        return row
    }

    private func statusText() -> String {
        let used = ByteCountFormatter.string(fromByteCount: store.diskUsage(), countStyle: .file)
        let total = store.totalRamText
        return "本机内存 \(total) · 已下载模型占用 \(used) · 所有模型均为开源权重"
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func badge(_ text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "  \(text)  ")
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = color
        label.wantsLayer = true
        label.layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
        label.layer?.cornerRadius = 6
        return label
    }

    private func badgeColor(_ level: String) -> NSColor {
        switch level {
        case "suggested": return .systemGreen
        case "moderate": return .systemOrange
        default: return .systemGray
        }
    }

    private func kindLabel(_ id: String) -> String {
        switch id {
        case "assist": return "候选优化"
        case "speech": return "语音输入"
        case "translate": return "同声传译"
        default: return id
        }
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 576).isActive = true
        return box
    }

    private func model(for sender: NSButton) -> AIModelInfo? {
        guard let id = sender.identifier?.rawValue else { return nil }
        return store.catalog.first { $0.id == id }
    }

    // MARK: - Actions

    @objc private func download(_ sender: NSButton) {
        guard let model = model(for: sender) else { return }
        store.onFinish = { [weak self] id, error in
            self?.refresh()
            if let error {
                let alert = NSAlert()
                alert.messageText = "下载失败"
                alert.informativeText = "\(id)：\(error)"
                alert.runModal()
            }
        }
        store.download(model)
        refresh()
    }

    @objc private func cancelDownload(_ sender: NSButton) {
        guard let model = model(for: sender) else { return }
        store.cancel(model)
        refresh()
    }

    @objc private func deleteModel(_ sender: NSButton) {
        guard let model = model(for: sender) else { return }
        for kind in model.kinds where AIModelStore.selectedModelId(for: kind) == model.id {
            AIModelStore.setSelectedModelId(nil, for: kind)
        }
        store.delete(model)
        refresh()
    }

    @objc private func toggleEnable(_ sender: NSButton) {
        guard let model = model(for: sender), let kind = model.kinds.first else { return }
        if AIModelStore.selectedModelId(for: kind) == model.id {
            AIModelStore.setSelectedModelId(nil, for: kind)
        } else {
            AIModelStore.setSelectedModelId(model.id, for: kind)
        }
        refresh()
    }
}
