import AppKit

/// 权限与隐私中心：每一个敏感能力——它碰什么数据、数据在哪、怎么关、怎么删——集中在一个窗口里。
/// 原则：能力默认最小化；关闭即清数据；这里看到的就是系统的全部敏感面。
final class PermissionCenterWindowController: NSWindowController {
    static let shared = PermissionCenterWindowController()

    private let stack = NSStackView()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "权限与隐私"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 480))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        scroll.documentView = stack
        window.contentView = scroll
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 内容

    private func buildUI() {
        let intro = NSTextField(wrappingLabelWithString: """
            InputFlow 的内核不发起任何网络请求。下面是这台机器上全部敏感能力与数据的位置：\
            每一项都可以关闭，关闭即清除对应数据；没有任何隐藏开关。
            """)
        intro.preferredMaxLayoutWidth = 520
        stack.addArrangedSubview(intro)
    }

    private func refresh() {
        // 保留开头的说明文字，重建其余行
        while stack.arrangedSubviews.count > 1 {
            let view = stack.arrangedSubviews.last
            stack.removeArrangedSubview(view!)
            view!.removeFromSuperview()
        }
        addSection(
            title: "剪切板历史",
            detail: "默认关闭。开启后记录复制过的文本，ChaCha20-Poly1305 加密存本地，上限 200 条。",
            dataPath: dataDir.appendingPathComponent("store.dat").path,
            toggleTitle: "剪切板记录",
            wipeTitle: "清空剪切板历史"
        )
        addSection(
            title: "用户词与短语学习",
            detail: "随输入在本机学习，加密落盘，密钥在系统钥匙串。可备份搬走，永不上传。",
            dataPath: dataDir.appendingPathComponent("store.dat").path,
            extraTitle: "打开词典目录…",
            extra: #selector(openDictionary(_:))
        )
        addSection(
            title: "知你学习账本",
            detail: "「上下文 → 候选词」的亲和度账本：只记哪个词在哪个上下文里被选过、被删过，无按键内容。删除窗口 10 秒内才会记负分。",
            dataPath: dataDir.appendingPathComponent("store.dat").path,
            toggleTitle: "知你学习",
            wipeTitle: "清空知你学习账本"
        )
        addSection(
            title: "知你营养库（喂食）",
            detail: "「喂它一段」从截图/文档提炼的专有名词：OCR 用 Apple Vision 端上识别，零网络；营养词只影响本机候选排序，逐条可忘。",
            dataPath: dataDir.appendingPathComponent("store.dat").path,
            wipeTitle: "清空营养库",
            extraTitle: "打开喂食窗…",
            extra: #selector(openFeed(_:))
        )
        addSection(
            title: "按应用记忆中/英",
            detail: "本地统计模型只存「应用 bundle id → 模式票数」，无按键内容。",
            dataPath: "UserDefaults（InputFlowAppModeMemoryTSV）",
            toggleTitle: "学习开关",
            wipeTitle: "清除全部学习结果"
        )
        addSection(
            title: "输入统计",
            detail: "只记次数与秒数：速度、纠错、回车、节省击键、最长发呆、卡路里估算。不记录任何按键内容，保留最近 7 天。傍晚总结走桌宠气泡，不申请系统通知权限。",
            dataPath: "UserDefaults（InputFlowStatsDays）",
            toggleTitle: "统计开关",
            wipeTitle: "清除全部统计数据"
        )
        addSection(
            title: "桌宠模式",
            detail: "形象包是声明式数据（图片 + 配置），无代码执行；鼠标追踪用 mouseLocation 轮询，不需要辅助功能权限。",
            dataPath: "仅记住窗口位置",
            toggleTitle: "桌宠"
        )
        let usage = ByteCountFormatter.string(fromByteCount: AIModelStore.shared.diskUsage(), countStyle: .file)
        addSection(
            title: "本地 AI 模型",
            detail: "零云 API：模型由你显式下载、sha256 校验后在本机运行；语音强制端上识别。",
            dataPath: AIModelStore.shared.modelsDirectory.path,
            wipeTitle: "删除全部已下载模型（\(usage)）"
        )
        let catalog = PluginStore.scan()
        let packSummary = "\(catalog.packs.count) 个数据包"
        addSection(
            title: "社区插件（\(packSummary)）",
            detail: "插件只有声明式数据包（皮肤/桌宠/词典），内核不执行任何插件代码；权限白名单制。"
                + (catalog.errors.isEmpty
                    ? ""
                    : " ⚠️ \(catalog.errors.count) 个包未通过校验被拒载。"),
            dataPath: PluginStore.pluginsDir.path,
            extraTitle: "打开插件目录…",
            extra: #selector(openPlugins(_:))
        )
    }

    private func addSection(
        title: String,
        detail: String,
        dataPath: String,
        toggleTitle: String? = nil,
        wipeTitle: String? = nil,
        extraTitle: String? = nil,
        extra: Selector? = nil
    ) {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4

        let head = NSTextField(labelWithString: title)
        head.font = .systemFont(ofSize: 13, weight: .semibold)
        column.addArrangedSubview(head)

        let desc = NSTextField(wrappingLabelWithString: detail)
        desc.preferredMaxLayoutWidth = 430
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor
        column.addArrangedSubview(desc)

        let path = NSTextField(wrappingLabelWithString: "数据位置：\(dataPath)")
        path.preferredMaxLayoutWidth = 430
        path.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        path.textColor = .tertiaryLabelColor
        column.addArrangedSubview(path)

        var controls: [NSView] = []
        if let toggleTitle {
            let button = NSButton(title: toggleTitle, target: self, action: #selector(permissionToggle(_:)))
            button.setButtonType(.switch)
            button.state = isToggleOn(title: toggleTitle) ? .on : .off
            controls.append(button)
        }
        if let wipeTitle {
            let button = NSButton(title: wipeTitle, target: self, action: #selector(wipeData(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.identifier = NSUserInterfaceItemIdentifier(title)
            controls.append(button)
        }
        if let extraTitle, let extra {
            let button = NSButton(title: extraTitle, target: self, action: extra)
            button.bezelStyle = .rounded
            button.controlSize = .small
            controls.append(button)
        }
        if !controls.isEmpty {
            let row = NSStackView(views: controls)
            row.orientation = .horizontal
            row.spacing = 10
            column.addArrangedSubview(row)
        }
        stack.addArrangedSubview(column)
        stack.addArrangedSubview(separator())
    }

    private var dataDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/InputFlow", isDirectory: true)
    }

    // MARK: - 动作

    private func isToggleOn(title: String) -> Bool {
        switch title {
        case "剪切板记录": return ClipboardMonitor.shared.isEnabled
        case "学习开关": return AppModeMemory.shared.isEnabled
        case "知你学习": return EvolutionLearning.isEnabled
        case "统计开关": return PetStats.shared.isEnabled
        case "桌宠": return PetWindowController.isEnabled
        default: return false
        }
    }

    @objc private func permissionToggle(_ sender: NSButton) {
        let on = sender.state == .on
        switch sender.title {
        case "剪切板记录": ClipboardMonitor.shared.setEnabled(on)
        case "学习开关": AppModeMemory.shared.isEnabled = on
        case "知你学习":
            EvolutionLearning.setEnabled(on)
            NotificationCenter.default.post(name: .evolutionToggled, object: nil)
        case "统计开关": PetStats.shared.isEnabled = on
        case "桌宠": PetWindowController.setEnabled(on)
        default: break
        }
        sender.state = on ? .on : .off
    }

    @objc private func wipeData(_ sender: NSButton) {
        switch sender.identifier?.rawValue {
        case "剪切板历史": EncryptedStore.shared.clearClipboard()
        case "按应用记忆中/英": AppModeMemory.shared.isEnabled = false
        case "知你学习账本": forgetEvolution()
        case "知你营养库（喂食）": forgetNutrition()
        case "输入统计": PetStats.shared.isEnabled = false
        case "本地 AI 模型": deleteAllModels()
        default: break
        }
        refresh()
    }

    /// 账本是进程单例：任意会话清空即全局清空。
    private func forgetEvolution() {
        InputFlowEngine(mode: "pinyin").forgetEvolution()
        EncryptedStore.shared.setEvolution("")
        PetWindowController.shared.showToast("知你学习账本已清空", duration: 3)
    }

    private func forgetNutrition() {
        let engine = InputFlowEngine(mode: "pinyin")
        engine.nutritionForgetAll()
        EncryptedStore.shared.setNutrition("")
        NotificationCenter.default.post(name: .nutritionChanged, object: nil)
        PetWindowController.shared.showToast("营养库已清空", duration: 3)
    }

    @objc private func openFeed(_ sender: NSButton) {
        FeedWindowController.shared.show()
    }

    private func deleteAllModels() {
        let store = AIModelStore.shared
        for model in InputFlowEngine.aiCatalog() where store.isInstalled(model) {
            store.delete(model)
        }
    }

    @objc private func openDictionary(_ sender: NSButton) {
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dataDir)
    }

    @objc private func openPlugins(_ sender: NSButton) {
        try? FileManager.default.createDirectory(at: PluginStore.pluginsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(PluginStore.pluginsDir)
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 520).isActive = true
        return box
    }
}
