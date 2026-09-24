import AppKit
import InputMethodKit

/// 输入控制器：把按键翻译为内核调用，并负责预编辑串与候选窗。
/// 不做任何网络访问；预编辑内容只在内存中，提交后立即释放。
@objc(InputFlowInputController)
final class InputFlowInputController: IMKInputController {
    private let engine = InputFlowEngine(
        mode: UserDefaults.standard.string(forKey: "InputFlowMode") ?? InputFlowMode.pinyin.rawValue
    )
    private let window = CandidateWindowController()
    private let store = EncryptedStore.shared
    private let clipboard = ClipboardMonitor.shared
    private let voice = VoiceInputController.shared
    private var voicePartial = ""
    /// 边说边落字：语音占用预编辑时为 true（update() 不得清、候选窗不得关）。
    private var voiceMarked = false
    private weak var currentClient: IMKTextInput?
    private var page = 0
    private var shiftArmed = false
    private var shiftUsed = false
    private var openDoubleQuote = true
    private var openSingleQuote = true
    /// 连按两下 `a` 的手势：上一次按 a 的时间（系统 uptime）。
    private var lastAAt: TimeInterval = 0
    /// 网址模式：所有按键直通系统，Esc 退出。
    private var urlMode = false
    /// 表情模式（斗图）之前的中文模式，Esc 时恢复。
    private var modeBeforeEmoji: String?
    private var lastChineseMode: InputFlowMode = {
        UserDefaults.standard.string(forKey: "InputFlowLastChineseMode")
            .flatMap(InputFlowMode.init(rawValue:))
            .flatMap { $0.isChinese ? $0 : nil } ?? .pinyin
    }()
    /// 当前活跃会话：桌宠点按/菜单动作只作用在它身上（IMK 每个客户端一个控制器实例）。
    private static weak var activeController: InputFlowInputController?
    /// 统计与发呆跟踪：上一次按键事件的时间戳。
    private var lastEventAt: TimeInterval?
    private var digestChecked = false

    /// 统计存储。
    private let stats = PetStats.shared

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        if !store.userModelTsv.isEmpty {
            _ = engine.importUserModel(store.userModelTsv)
        }
        engine.setTraditional(UserDefaults.standard.bool(forKey: Self.traditionalKey))
        observePetActions()
    }

    /// 桌宠与菜单的跨实例动作走通知；只有活跃会话响应。
    private func observePetActions() {
        NotificationCenter.default.addObserver(
            forName: .petToggleLanguage, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, Self.activeController === self else { return }
            self.toggleLanguage()
            self.refreshPetModeLabel()
        }
        NotificationCenter.default.addObserver(
            forName: .petTogglePunctuation, object: nil, queue: .main
        ) { [weak self] _ in
            guard Self.activeController === self else { return }
            let key = "InputFlowForceHalfPunctuation"
            let on = !UserDefaults.standard.bool(forKey: key)
            UserDefaults.standard.set(on, forKey: key)
            PetWindowController.shared.showToast(on ? "已强制半角标点（全局）" : "标点恢复按应用自动", duration: 4)
        }
        NotificationCenter.default.addObserver(
            forName: .petShowStats, object: nil, queue: .main
        ) { [weak self] _ in
            guard Self.activeController === self else { return }
            PetWindowController.shared.showStatsCard(yesterday: true)
        }
    }

    private func refreshPetModeLabel() {
        let chinese = (InputFlowMode(rawValue: engine.mode) ?? .pinyin).isChinese
        PetWindowController.shared.setModeLabel(chinese: chinese)
    }

    /// 繁体输出开关（跨会话记住）。
    static let traditionalKey = "InputFlowTraditional"

    required init?(coder: NSCoder) { nil }

    // MARK: - 模式菜单

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "InputFlow")
        let header = NSMenuItem(title: "输入模式", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let current = engine.mode
        for mode in InputFlowMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode.rawValue == current ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let pet = NSMenuItem(title: "桌宠模式", action: #selector(togglePetMode(_:)), keyEquivalent: "")
        pet.target = self
        pet.state = PetWindowController.isEnabled ? .on : .off
        menu.addItem(pet)
        let petSkin = NSMenuItem(title: "桌宠形象", action: nil, keyEquivalent: "")
        petSkin.submenu = petSubmenu()
        menu.addItem(petSkin)
        let skins = NSMenuItem(title: "皮肤", action: nil, keyEquivalent: "")
        skins.submenu = skinSubmenu()
        menu.addItem(skins)
        let perms = NSMenuItem(title: "权限与隐私…", action: #selector(openPermissionCenter(_:)), keyEquivalent: "")
        perms.target = self
        menu.addItem(perms)
        let mem = NSMenuItem(title: "按应用记忆中/英", action: #selector(toggleAppModeMemory(_:)), keyEquivalent: "")
        mem.target = self
        mem.state = AppModeMemory.shared.isEnabled ? .on : .off
        menu.addItem(mem)
        let forgetMem = NSMenuItem(title: "忘记此应用的中英偏好", action: #selector(forgetAppModeMemory(_:)), keyEquivalent: "")
        forgetMem.target = self
        menu.addItem(forgetMem)
        let punct = NSMenuItem(title: "强制半角标点", action: #selector(toggleHalfPunctuation(_:)), keyEquivalent: "")
        punct.target = self
        punct.state = UserDefaults.standard.bool(forKey: "InputFlowForceHalfPunctuation") ? .on : .off
        menu.addItem(punct)
        let statsItem = NSMenuItem(title: "昨日输入总结", action: #selector(showYesterdayStats(_:)), keyEquivalent: "")
        statsItem.target = self
        menu.addItem(statsItem)
        let clipItem = NSMenuItem(title: "剪切板历史", action: nil, keyEquivalent: "")
        clipItem.submenu = clipboardSubmenu()
        menu.addItem(clipItem)
        let trad = NSMenuItem(title: "繁体输出", action: #selector(toggleTraditional(_:)), keyEquivalent: "")
        trad.target = self
        trad.state = engine.isTraditional ? .on : .off
        menu.addItem(trad)

        let voiceItem = NSMenuItem(
            title: voice.isListening ? "停止语音输入" : "语音输入（端上识别）",
            action: #selector(toggleVoice(_:)),
            keyEquivalent: ""
        )
        voiceItem.target = self
        voiceItem.state = voice.isListening ? .on : .off
        menu.addItem(voiceItem)
        let backup = NSMenuItem(title: "备份与恢复", action: nil, keyEquivalent: "")
        backup.submenu = backupSubmenu()
        menu.addItem(backup)
        let ai = NSMenuItem(title: "AI 增强…", action: #selector(openAISettings(_:)), keyEquivalent: "")
        ai.target = self
        menu.addItem(ai)
        let prefs = NSMenuItem(title: "打开词典目录…", action: #selector(openDictionaryFolder(_:)), keyEquivalent: "")
        prefs.target = self
        menu.addItem(prefs)
        return menu
    }

    private func backupSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "备份与恢复")
        for (title, action) in [
            ("导出加密备份…", #selector(exportEncryptedBackup(_:))),
            ("导出明文备份…", #selector(exportPlainBackup(_:))),
            ("从备份恢复…", #selector(restoreBackup(_:))),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            submenu.addItem(item)
        }
        let note = NSMenuItem(title: "（只含用户词与短语，不含剪切板）", action: nil, keyEquivalent: "")
        note.isEnabled = false
        submenu.addItem(.separator())
        submenu.addItem(note)
        return submenu
    }

    private func clipboardSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "剪切板历史")
        if clipboard.isEnabled {
            if store.clipboard.isEmpty {
                let empty = NSMenuItem(title: "（暂无记录）", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                submenu.addItem(empty)
            } else {
                for item in store.clipboard.prefix(8) {
                    let firstLine = item.text.split(separator: "\n").first.map(String.init) ?? item.text
                    let title = firstLine.count > 26 ? String(firstLine.prefix(26)) + "…" : firstLine
                    let entry = NSMenuItem(title: title, action: #selector(insertClipboardItem(_:)), keyEquivalent: "")
                    entry.target = self
                    entry.representedObject = item.text
                    submenu.addItem(entry)
                }
            }
            submenu.addItem(.separator())
            let off = NSMenuItem(title: "关闭剪切板记录", action: #selector(disableClipboardRecording(_:)), keyEquivalent: "")
            off.target = self
            submenu.addItem(off)
        } else {
            let on = NSMenuItem(title: "开启剪切板记录…", action: #selector(openClipboardWindow(_:)), keyEquivalent: "")
            on.target = self
            submenu.addItem(on)
        }
        let open = NSMenuItem(title: "打开剪切板历史…", action: #selector(openClipboardWindow(_:)), keyEquivalent: "")
        open.target = self
        submenu.addItem(open)
        return submenu
    }

    @objc private func insertClipboardItem(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        if let client = currentClient {
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        } else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            clipboard.ignore(text)
        }
    }

    @objc private func openClipboardWindow(_ sender: Any) {
        ClipboardWindowController.shared.show()
    }

    @objc private func disableClipboardRecording(_ sender: Any) {
        clipboard.setEnabled(false)
        let alert = NSAlert()
        alert.messageText = "已关闭剪切板记录"
        alert.informativeText = "已有历史保留在本地加密文件中，可在「剪切板历史…」中查看或清空。"
        alert.runModal()
    }

    @objc private func openAISettings(_ sender: Any) {
        AISettingsWindowController.shared.show()
    }

    @objc private func toggleTraditional(_ sender: NSMenuItem) {
        let on = !engine.isTraditional
        engine.setTraditional(on)
        UserDefaults.standard.set(on, forKey: Self.traditionalKey)
        sender.state = on ? .on : .off
        if let client = currentClient {
            update(client)
        }
    }

    @objc private func exportEncryptedBackup(_ sender: Any) {
        syncUserModel()
        BackupManager.exportEncrypted(engine: engine)
    }

    @objc private func exportPlainBackup(_ sender: Any) {
        syncUserModel()
        BackupManager.exportPlain(engine: engine)
    }

    @objc private func restoreBackup(_ sender: Any) {
        BackupManager.restore(engine: engine, store: store)
    }

    /// 导出前把两边对齐：先把本会话的学习结果并进落盘数据，再整份读回会话，
    /// 免得导出的备份缺了别的窗口刚学到的词。
    private func syncUserModel() {
        persistUserModel()
        if !store.userModelTsv.isEmpty {
            _ = engine.importUserModel(store.userModelTsv)
        }
    }

    @objc private func togglePetMode(_ sender: NSMenuItem) {
        PetWindowController.setEnabled(!PetWindowController.isEnabled)
        sender.state = PetWindowController.isEnabled ? .on : .off
    }

    @objc private func toggleAppModeMemory(_ sender: NSMenuItem) {
        AppModeMemory.shared.isEnabled.toggle() // 关闭时顺带清空学习结果
        sender.state = AppModeMemory.shared.isEnabled ? .on : .off
    }

    @objc private func forgetAppModeMemory(_ sender: NSMenuItem) {
        AppModeMemory.shared.forget(appId: currentAppId)
    }

    /// 皮肤子菜单：跟随系统 + 社区皮肤包。
    private func skinSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "皮肤")
        let active = ThemeStore.activeId
        let system = NSMenuItem(title: "跟随系统", action: #selector(selectSkin(_:)), keyEquivalent: "")
        system.target = self
        system.representedObject = ""
        system.state = active.isEmpty ? .on : .off
        submenu.addItem(system)
        for pack in ThemeStore.availableSkins() {
            let item = NSMenuItem(
                title: "\(pack.name)（v\(pack.version)）",
                action: #selector(selectSkin(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = pack.id
            item.state = pack.id == active ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func selectSkin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        ThemeStore.activeId = id
        for item in sender.menu?.items ?? [] {
            item.state = (item.representedObject as? String) == id ? .on : .off
        }
    }

    /// 桌宠形象子菜单：内置 emoji 形象 + 社区形象包。
    private func petSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "桌宠形象")
        let active = PetWindowController.activePackId

        // 内置 emoji 形象（默认推荐：系统绘制，干净不糊）
        let emojiHeader = NSMenuItem(title: "内置表情", action: nil, keyEquivalent: "")
        emojiHeader.isEnabled = false
        submenu.addItem(emojiHeader)
        let emojis = ["🐱", "🐶", "🦊", "🐼", "🐹", "🐰", "🐧", "🤖", "👧", "🧑‍🎨"]
        for emoji in emojis {
            let item = NSMenuItem(title: "\(emoji)  内置表情", action: #selector(selectPetEmoji(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = emoji
            item.state = (active.isEmpty && PetWindowController.builtinEmoji == emoji) ? .on : .off
            submenu.addItem(item)
        }

        let framingMenu = NSMenu(title: "画幅")
        for (title, value) in [("全身（显身材）", "full"), ("半身（看表情）", "bust")] {
            let item = NSMenuItem(title: title, action: #selector(selectPetFraming(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = PetWindowController.framingOverride == value ? .on : .off
            framingMenu.addItem(item)
        }
        let zoomMenu = NSMenu(title: "缩放")
        for value in [0.8, 1.0, 1.25, 1.5] {
            let item = NSMenuItem(title: String(format: "%.0f%%", value * 100), action: #selector(selectPetZoom(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(PetWindowController.zoomOverride - value) < 0.01 ? .on : .off
            zoomMenu.addItem(item)
        }
        let framingItem = NSMenuItem(title: "画幅", action: nil, keyEquivalent: "")
        framingItem.submenu = framingMenu
        submenu.addItem(framingItem)
        let zoomItem = NSMenuItem(title: "缩放", action: nil, keyEquivalent: "")
        zoomItem.submenu = zoomMenu
        submenu.addItem(zoomItem)

        let catalogItem = NSMenuItem(title: "形象目录…", action: #selector(openPetCatalog(_:)), keyEquivalent: "")
        catalogItem.target = self
        submenu.addItem(catalogItem)

        let seedItem = NSMenuItem(
            title: "下载官方样例 Seed-san（VRM Public License 1.0）…",
            action: #selector(downloadSeedSan(_:)),
            keyEquivalent: ""
        )
        seedItem.target = self
        submenu.addItem(seedItem)

        let importItem = NSMenuItem(title: "导入 VRM 模型…", action: #selector(importVRM(_:)), keyEquivalent: "")
        importItem.target = self
        submenu.addItem(importItem)

        submenu.addItem(.separator())
        let packHeader = NSMenuItem(title: "形象包", action: nil, keyEquivalent: "")
        packHeader.isEnabled = false
        submenu.addItem(packHeader)
        for pack in PetWindowController.availablePets() {
            let item = NSMenuItem(
                title: "\(pack.name)（v\(pack.version)）",
                action: #selector(selectPetPack(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = pack.id
            item.toolTip = pack.description
            item.state = pack.id == active ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func selectPetEmoji(_ sender: NSMenuItem) {
        guard let emoji = sender.representedObject as? String else { return }
        PetWindowController.builtinEmoji = emoji
        if !PetWindowController.isEnabled {
            PetWindowController.setEnabled(true)
        }
        for item in sender.menu?.items ?? [] {
            item.state = (item.representedObject as? String) == emoji ? .on : .off
        }
        PetWindowController.shared.showToast("已切换桌宠形象：\(emoji)", duration: 2.5)
    }

    @objc private func selectPetPack(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        PetWindowController.activePackId = id
        if !PetWindowController.isEnabled {
            PetWindowController.setEnabled(true)
        }
        for item in sender.menu?.items ?? [] {
            item.state = (item.representedObject as? String) == id ? .on : .off
        }
        PetWindowController.shared.showToast("已切换桌宠形象：\(sender.title)", duration: 2.5)
    }

    @objc private func selectPetFraming(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        PetWindowController.framingOverride = value
        for item in sender.menu?.items ?? [] {
            item.state = (item.representedObject as? String) == value ? .on : .off
        }
    }

    @objc private func selectPetZoom(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        PetWindowController.zoomOverride = value
        for item in sender.menu?.items ?? [] {
            item.state = abs(((item.representedObject as? Double) ?? -1) - value) < 0.01 ? .on : .off
        }
    }

    /// 语音输入：识别结果「边说边落字」（实时预编辑 + 候选 #1 融合）；
    /// 空格 / 1 / 回车 / 点击候选上屏，Esc 取消，打字自动接管（先落字再拼拼音）。
    @objc private func toggleVoice(_ sender: NSMenuItem) {
        if voice.isListening {
            stopVoice()
            if voiceMarked, let client = activeClient() {
                clearMarkedText(client)
                voiceMarked = false
            }
            window.hide()
            return
        }
        voice.onPartial = { [weak self] text in
            guard let self, self.voice.isListening else { return }
            self.voicePartial = text
            guard let client = self.activeClient() else { return }
            if self.engine.hasComposition {
                // 打字优先：不抢拼音的预编辑，只在旁边提示
                self.window.presentHint("🎤 " + text, near: self.caretRect(client))
                return
            }
            // 边说边落字：实时写进预编辑（强调色下划线）
            let attributed = NSAttributedString(string: text, attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: NSColor.controlAccentColor,
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            ])
            client.setMarkedText(
                attributed,
                selectionRange: NSRange(location: attributed.length, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            self.voiceMarked = true
            self.page = 0
            // 语音候选融合：识别结果作为候选 #1，可点击或按 1 上屏
            let voiceCandidate = Candidate(
                text: text, consumed: 0, kind: "voice", comment: "语音"
            )
            self.window.present(
                candidates: [voiceCandidate],
                page: 0,
                near: self.caretRect(client)
            ) { [weak self, weak client] _ in
                guard let self, let client else { return }
                self.commitVoice(self.voicePartial, client: client)
            }
        }
        voice.onFinal = { [weak self] text in
            guard let self, self.voice.isListening else { return }
            guard !self.engine.hasComposition, let client = self.activeClient() else {
                // 打字已接管或焦点已丢：不再抢上屏
                self.stopVoice()
                return
            }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.commitVoice(value.isEmpty ? self.voicePartial : value, client: client)
        }
        voice.onStatus = { message in
            PetWindowController.shared.showToast(message, duration: 4)
        }
        voice.start()
    }

    private func activeClient() -> IMKTextInput? {
        currentClient ?? (client as? IMKTextInput)
    }

    /// 停止监听并清掉未上屏的识别文本（菜单每次打开按状态重建，无需手改标题）。
    private func stopVoice() {
        if voice.isListening { voice.stop() }
        voicePartial = ""
    }

    /// 统一的语音上屏：空格 / 1 / 回车 / 点击候选 / 识别结束都走这里。
    private func commitVoice(_ text: String, client: IMKTextInput) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        stopVoice()
        if !value.isEmpty {
            // insertText 会替换当前 marked 区域（边说边落字的内容）
            client.insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0))
            voiceMarked = false
            engine.recordCommit(value)
            persistUserModel()
            stats.recordCommit(chars: value.count, keys: 0)
            recordModeSignal(strong: false)
            PetWindowController.shared.react(.commit)
        } else if voiceMarked {
            clearMarkedText(client)
            voiceMarked = false
        }
        window.hide()
    }

    /// 语音让位给打字：先落下已识别文本再停监听（说→打无缝衔接）。
    private func absorbVoice(client: IMKTextInput) {
        let pending = voicePartial
        stopVoice()
        if !pending.isEmpty {
            client.insertText(pending, replacementRange: NSRange(location: NSNotFound, length: 0))
            voiceMarked = false
            engine.recordCommit(pending)
            persistUserModel()
            stats.recordCommit(chars: pending.count, keys: 0)
            recordModeSignal(strong: false)
            PetWindowController.shared.react(.commit)
        } else if voiceMarked {
            clearMarkedText(client)
            voiceMarked = false
        }
    }

    @objc private func openPetCatalog(_ sender: Any) {
        PetCatalogWindowController.shared.show()
    }

    /// 一键下载官方样例 VRM（用户点击才联网，sha256 校验后才安装）。
    @objc private func downloadSeedSan(_ sender: Any) {
        PetWindowController.shared.showToast("开始下载 Seed-san（约 10MB，VRM 官方样例）…", duration: 5)
        PetModelInstaller.install(
            PetModelCatalog.seedSan,
            onProgress: { _ in },
            completion: { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        PetWindowController.shared.showToast(
                            "Seed-san 已下载（sha256 校验通过）；在「桌宠形象」里可选",
                            duration: 5
                        )
                    case .failure(let error):
                        PetWindowController.shared.showToast("下载失败：\(error.localizedDescription)", duration: 6)
                    }
                }
            }
        )
    }

    /// 导入用户自己的 VRM 模型（VRoid Studio 可免费导出），生成 vrm-custom 形象包。
    @objc private func importVRM(_ sender: Any) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择 VRM 模型文件（VRoid Studio 可免费导出）"
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.init(filenameExtension: "vrm") ?? .data]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let fm = FileManager.default
        let dest = PluginStore.pluginsDir.appendingPathComponent("vrm-custom", isDirectory: true)
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            let model = dest.appendingPathComponent("model.vrm")
            try? fm.removeItem(at: model)
            try fm.copyItem(at: url, to: model)
            let plugin = """
            {"id":"vrm-custom","name":"自定义 VRM","version":"1.0.0","kind":"pet",\
            "authors":["user"],"description":"导入的 VRM 模型：\(url.lastPathComponent)","license":"user-provided","permissions":[]}
            """
            let pet = """
            {"renderer":"vrm","size":220,"fps":30,"fps_idle":30,"fps_typing":60,\
            "entry":"model.vrm","follow_cursor":false,"typing_bounce":true,"commit_particles":true}
            """
            try plugin.data(using: .utf8)?.write(to: dest.appendingPathComponent("plugin.json"))
            try pet.data(using: .utf8)?.write(to: dest.appendingPathComponent("pet.json"))
            PetWindowController.activePackId = "vrm-custom"
            if !PetWindowController.isEnabled {
                PetWindowController.setEnabled(true)
            }
            PetWindowController.shared.showToast("已导入 VRM：\(url.lastPathComponent)", duration: 4)
        } catch {
            PetWindowController.shared.showToast("导入失败：\(error.localizedDescription)", duration: 6)
        }
    }

    @objc private func openPermissionCenter(_ sender: Any) {
        PermissionCenterWindowController.shared.show()
    }

    /// 当前前台应用画像（代码/浏览器/聊天），决定标点与手势能力；
    /// 「强制半角标点」打开时全局覆盖（快捷配置入口：桌宠右键 / 本菜单）。
    private var profile: AppProfile {
        let bundleId = currentClient?.bundleIdentifier() ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var p = AppProfile.make(bundleId: bundleId)
        if UserDefaults.standard.bool(forKey: "InputFlowForceHalfPunctuation") {
            p.asciiPunctuation = true
        }
        return p
    }

    @objc private func toggleHalfPunctuation(_ sender: NSMenuItem) {
        let key = "InputFlowForceHalfPunctuation"
        let on = !UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(on, forKey: key)
        sender.state = on ? .on : .off
    }

    @objc private func showYesterdayStats(_ sender: Any) {
        PetWindowController.shared.showStatsCard(yesterday: true)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard
            let id = sender.representedObject as? String,
            let mode = InputFlowMode(rawValue: id)
        else { return }
        modeBeforeEmoji = nil
        engine.setMode(id)
        if mode.isChinese { lastChineseMode = mode }
        persist(mode: mode)
        recordModeSignal(strong: true)
        for item in sender.menu?.items ?? [] {
            item.state = (item.representedObject as? String) == id ? .on : .off
        }
    }

    @objc private func openDictionaryFolder(_ sender: Any) {
        let path = NSHomeDirectory() + "/Library/Application Support/InputFlow"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func persist(mode: InputFlowMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "InputFlowMode")
        UserDefaults.standard.set(lastChineseMode.rawValue, forKey: "InputFlowLastChineseMode")
    }

    private func toggleLanguage() {
        let current = InputFlowMode(rawValue: engine.mode) ?? .pinyin
        let next: InputFlowMode
        if current.isChinese {
            lastChineseMode = current
            next = .en
        } else {
            next = lastChineseMode
        }
        engine.setMode(next.rawValue)
        persist(mode: next)
        recordModeSignal(strong: true)
        window.hide()
        // 明确反馈：避免「以为还能打中文、其实已切英文」的困惑
        PetWindowController.shared.showToast(
            next == .en
                ? "已切到 English（再单按左 Shift 或点桌宠切回中文）"
                : "已切回中文输入",
            duration: 3
        )
    }

    /// 当前前台应用 bundle id（用于每应用中英记忆）。
    private var currentAppId: String? {
        currentClient?.bundleIdentifier() ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// 把当前模式作为学习信号记录：手动切换是强信号，上屏是弱信号。
    /// 表情等特殊模式不在 InputFlowMode 里，不计票。
    private func recordModeSignal(strong: Bool) {
        guard let mode = InputFlowMode(rawValue: engine.mode) else { return }
        AppModeMemory.shared.observe(appId: currentAppId, chinese: mode.isChinese, strong: strong)
    }

    /// 切到某个应用时，按学到的偏好恢复中/英。
    /// 样本足够（强票或明显优势）才动手；单次意外切换会被下一次切回抵消，不会纠缠。
    private func restoreModeForApp() {
        guard AppModeMemory.shared.isEnabled, modeBeforeEmoji == nil, !urlMode else { return }
        guard let current = InputFlowMode(rawValue: engine.mode), current != .ja else { return }
        guard let preferChinese = AppModeMemory.shared.preferredChinese(appId: currentAppId) else { return }
        if preferChinese, !current.isChinese {
            engine.setMode(lastChineseMode.rawValue)
            persist(mode: lastChineseMode)
            showModeHint("已切回\(lastChineseMode.title)（记住的偏好）")
        } else if !preferChinese, current.isChinese {
            engine.setMode(InputFlowMode.en.rawValue)
            persist(mode: .en)
            showModeHint("已切到 English（记住的偏好）")
        }
    }

    private func showModeHint(_ text: String) {
        window.presentHint(text, near: currentClient.flatMap { caretRect($0) })
    }

    // MARK: - 事件处理

    override func inputText(_ string: String!, client sender: Any!) -> Bool {
        false
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else { return false }

        // 网址模式：按键全部直通系统（浏览器自己处理），Esc / 回车退出。
        if urlMode, event.type == .keyDown, !event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 53:
                exitURLMode()
                return true
            case 36, 76:
                exitURLMode()
                return false
            default:
                return false
            }
        }

        if event.type == .flagsChanged {
            return handleFlagsChanged(event)
        }
        guard event.type == .keyDown else { return false }
        if shiftArmed { shiftUsed = true }

        // 统计：发呆结束（≥5s）或活跃打字（<10s）；只记秒数与次数。
        let nowTick = Date().timeIntervalSince1970
        if let last = lastEventAt {
            let gap = nowTick - last
            if gap >= 5 {
                stats.recordStare(seconds: gap)
            } else if gap < 10 {
                stats.recordActive(seconds: gap)
            }
        }
        lastEventAt = nowTick

        let flags = event.modifierFlags
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            return false
        }

        let keyCode = event.keyCode
        if keyCode == 51 {
            stats.recordDelete()  // 删除键：含组合态外的原编辑
        }
        if keyCode == 36 || keyCode == 76 {
            stats.recordEnter()  // 回车键：同上
        }

        switch keyCode {
        case 53: // Esc
            if voice.isListening {
                let hadMarked = voiceMarked
                stopVoice()
                if hadMarked {
                    clearMarkedText(client)
                    voiceMarked = false
                }
                window.hide()
                return true
            }
            if engine.mode == "emoji" {
                exitEmojiMode(client: client)
                return true
            }
            guard engine.hasComposition else { return false }
            engine.clear()
            window.hide()
            update(client)
            return true
        case 36, 76: // Return
            if voice.isListening, !voicePartial.isEmpty, !engine.hasComposition {
                commitVoice(voicePartial, client: client)
                return true
            }
            guard engine.hasComposition else { return false }
            let keys = engine.composition.raw.count
            if let raw = engine.commitRaw() {
                stats.recordCommit(chars: raw.count, keys: keys)
                commit(raw, client: client)
            }
            return true
        case 51: // Delete
            guard engine.hasComposition else { return false }
            _ = engine.backspace()
            update(client)
            return true
        case 49: // Space
            if voice.isListening, !voicePartial.isEmpty, !engine.hasComposition {
                commitVoice(voicePartial, client: client)
                return true
            }
            guard engine.hasComposition || engine.mode == "emoji" else { return false }
            select(index: page * CandidateWindowController.pageSize, client: client)
            return true
        default:
            break
        }

        if engine.hasComposition || engine.mode == "emoji" {
            let pageCount = max(1, Int(ceil(Double(currentCandidateCount()) / Double(CandidateWindowController.pageSize))))
            switch keyCode {
            case 123, 116: // ← / PageUp
                page = max(0, page - 1)
                update(client)
                return true
            case 124, 121: // → / PageDown
                page = min(pageCount - 1, page + 1)
                update(client)
                return true
            case 27: // -
                page = max(0, page - 1)
                update(client)
                return true
            case 24: // =
                page = min(pageCount - 1, page + 1)
                update(client)
                return true
            default:
                break
            }
            if let chars = event.charactersIgnoringModifiers, let n = Int(chars), (1...9).contains(n) {
                select(index: page * CandidateWindowController.pageSize + n - 1, client: client)
                return true
            }
        }

        // 语音候选只有一条：按 1 直接上屏（避免落进普通流程把 "1" 打出来）
        if voice.isListening, !voicePartial.isEmpty, !engine.hasComposition,
           event.charactersIgnoringModifiers == "1" {
            commitVoice(voicePartial, client: client)
            return true
        }

        guard let chars = event.charactersIgnoringModifiers else { return false }

        // 语音进行中遇到普通按键：先落下已识别文本，再继续处理本键（说→打无缝衔接）
        if voice.isListening {
            absorbVoice(client: client)
        }

        // 连按两下 a：浏览器 → 网址模式；聊天工具 → 表情模式（斗图）。
        if chars == "a", !event.isARepeat, !flags.contains(.shift) {
            let now = ProcessInfo.processInfo.systemUptime
            if engine.composition.raw == "a", now - lastAAt < 0.3 {
                lastAAt = 0
                engine.clear()
                if profile.urlGesture {
                    enterURLMode(client: client)
                    return true
                }
                if profile.memeGesture {
                    enterEmojiMode(client: client)
                    return true
                }
                // 当前应用没有手势动作：还原为正常的 aa 输入
                _ = engine.feed("a")
                _ = engine.feed("a")
                page = 0
                update(client)
                return true
            }
            lastAAt = now
        }

        // 中文模式下的标点映射（未组合时）：`,。？！；：、（）【】《》“”‘’…
        // 代码编辑器/终端保持半角（按应用画像自动判断，无需用户配置）。
        let mode = InputFlowMode(rawValue: engine.mode) ?? .pinyin
        if !engine.hasComposition, mode.usesChinesePunctuation, !profile.asciiPunctuation,
           let punct = chinesePunctuation(chars) {
            client.insertText(punct, replacementRange: NSRange(location: NSNotFound, length: 0))
            window.hide()
            return true
        }

        var accepted = false
        var fed = 0
        for ch in chars {
            if engine.feed(ch) {
                accepted = true
                fed += 1
            } else {
                break
            }
        }
        if accepted {
            stats.recordKeys(fed)
            page = 0
            update(client)
        }
        return accepted
    }

    override func commitComposition(_ sender: Any!) {
        if voice.isListening, let voiceClient = sender as? IMKTextInput {
            absorbVoice(client: voiceClient)
        }
        if let client = sender as? IMKTextInput {
            let keys = engine.composition.raw.count
            if let raw = engine.commitRaw() {
                stats.recordCommit(chars: raw.count, keys: keys)
                client.insertText(raw, replacementRange: NSRange(location: NSNotFound, length: 0))
                recordModeSignal(strong: false)
                persistUserModel()
            }
        }
        window.hide()
    }

    override func deactivateServer(_ sender: Any!) {
        stopVoice()
        voiceMarked = false
        engine.clear()
        urlMode = false
        // 会话结束：截断发呆计时，避免跨应用间隙被误计
        if let last = lastEventAt {
            let gap = Date().timeIntervalSince1970 - last
            if gap >= 5 {
                stats.recordStare(seconds: gap)
            }
        }
        lastEventAt = nil
        if Self.activeController === self {
            Self.activeController = nil
        }
        if let previous = modeBeforeEmoji {
            engine.setMode(previous)
            modeBeforeEmoji = nil
        }
        PetWindowController.shared.react(.idle)
        if let client = sender as? IMKTextInput {
            clearMarkedText(client)
        }
        window.hide()
        store.flush()
        super.deactivateServer(sender)
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        currentClient = sender as? IMKTextInput
        Self.activeController = self
        page = 0
        restoreModeForApp()
        refreshPetModeLabel()
        maybeEveningDigest()
    }

    /// 傍晚总结：18 点后当天第一次激活时弹一次今日小结气泡。
    /// 不用系统通知权限——进程活着才会弹，属于「打字时顺带看到」。
    private func maybeEveningDigest() {
        guard !digestChecked else { return }
        digestChecked = true
        guard PetStats.shared.isEnabled else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= 18 else { return }
        let today = PetStats.dayKey()
        guard UserDefaults.standard.string(forKey: "InputFlowDigestShown") != today else { return }
        UserDefaults.standard.set(today, forKey: "InputFlowDigestShown")
        PetWindowController.shared.showStatsCard(yesterday: false)
    }

    // MARK: - 内部

    /// ASCII 标点 → 中文全角标点；返回 nil 表示不拦截。
    /// 引号成对翻转，`^` 输出省略号，`\` 输出顿号。
    private func chinesePunctuation(_ s: String) -> String? {
        switch s {
        case ",": return "，"
        case ".": return "。"
        case "?": return "？"
        case "!": return "！"
        case ":": return "："
        case ";": return "；"
        case "(": return "（"
        case ")": return "）"
        case "[": return "【"
        case "]": return "】"
        case "{": return "「"
        case "}": return "」"
        case "<": return "《"
        case ">": return "》"
        case "\\": return "、"
        case "|": return "｜"
        case "~": return "～"
        case "^": return "……"
        case "$": return "¥"
        case "`": return "·"
        case "\"":
            defer { openDoubleQuote.toggle() }
            return openDoubleQuote ? "“" : "”"
        case "'":
            defer { openSingleQuote.toggle() }
            return openSingleQuote ? "‘" : "’"
        default:
            return nil
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) -> Bool {
        guard event.keyCode == 56 || event.keyCode == 60 else { return false }
        if event.modifierFlags.contains(.shift) {
            shiftArmed = true
            shiftUsed = false
        } else if shiftArmed {
            let shouldToggle = !shiftUsed && !engine.hasComposition
            shiftArmed = false
            if shouldToggle { toggleLanguage() }
        }
        return false
    }

    private func currentCandidateCount() -> Int {
        engine.composition.candidates.count
    }

    private func select(index: Int, client: IMKTextInput) {
        let keys = engine.composition.raw.count
        guard let text = engine.select(index) else {
            NSSound.beep()
            return
        }
        stats.recordCommit(chars: text.count, keys: keys)
        commit(text, client: client)
    }

    private func commit(_ text: String, client: IMKTextInput) {
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        recordModeSignal(strong: false)
        persistUserModel()
        PetWindowController.shared.react(.commit)
        page = 0
        update(client)
    }

    /// 把会话内学到的用户词（含上下词二元组）合并进加密存储。
    private func persistUserModel() {
        store.mergeUserModel(tsv: engine.exportUserModel())
    }

    // MARK: - 网址模式 / 表情模式

    private func enterURLMode(client: IMKTextInput) {
        urlMode = true
        window.presentHint("网址模式 · 输入完成后按 Esc 退出", near: caretRect(client))
        PetWindowController.shared.react(.idle)
    }

    private func exitURLMode() {
        urlMode = false
        window.hide()
    }

    private func enterEmojiMode(client: IMKTextInput) {
        let current = engine.mode
        if current != "emoji" {
            modeBeforeEmoji = current
            engine.setMode("emoji")
        }
        page = 0
        update(client)
    }

    private func exitEmojiMode(client: IMKTextInput) {
        if let previous = modeBeforeEmoji {
            engine.setMode(previous)
            modeBeforeEmoji = nil
        }
        page = 0
        update(client)
        window.hide()
    }

    private func update(_ client: IMKTextInput) {
        let comp = engine.composition
        guard !comp.raw.isEmpty || !comp.candidates.isEmpty else {
            // 语音正在「边说边落字」时，预编辑与候选窗归语音所有，不许清
            if !voiceMarked { clearMarkedText(client) }
            if !voice.isListening { window.hide() }
            PetWindowController.shared.react(.idle)
            return
        }
        PetWindowController.shared.react(comp.raw.isEmpty ? .idle : .composing)
        let display = comp.preedit.isEmpty ? comp.raw : comp.preedit
        if display.isEmpty {
            // 表情模式的精选列表：不产生预编辑串，只展示候选窗
            clearMarkedText(client)
        } else {
            // 预编辑：当前正在拼的音节用强调色 + 加粗，其余常规下划线
            let pieces = display.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            let marked = NSMutableAttributedString()
            for (index, piece) in pieces.enumerated() {
                let active = index == pieces.count - 1 && pieces.count > 1
                let attributes: [NSAttributedString.Key: Any] = [
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: active ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
                    .foregroundColor: active ? NSColor.controlAccentColor : NSColor.labelColor,
                    .font: NSFont.systemFont(ofSize: 15, weight: active ? .semibold : .regular),
                ]
                marked.append(NSAttributedString(string: piece, attributes: attributes))
                if index < pieces.count - 1 {
                    marked.append(NSAttributedString(string: " "))
                }
            }
            client.setMarkedText(
                marked,
                selectionRange: NSRange(location: marked.length, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
        }
        let caret = caretRect(client)
        if let caret {
            // 输入法在哪块屏幕工作，桌宠就在哪块屏幕互动
            PetWindowController.shared.moveToScreen(
                containing: NSPoint(x: caret.midX, y: caret.midY)
            )
        }
        window.present(candidates: comp.candidates, page: page, near: caret) { [weak self, weak client] index in
            guard let self, let client else { return }
            self.select(index: index, client: client)
        }
        page = window.page
    }

    private func clearMarkedText(_ client: IMKTextInput) {
        client.setMarkedText(
            "",
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    private func caretRect(_ client: IMKTextInput) -> NSRect? {
        // attributes 返回的是光标所在行的矩形（屏幕坐标，AppKit 原点），是 IME 最稳的定位方式；
        // firstRect 在部分应用里对 NSNotFound 范围返回无效值，放在其后兜底。
        var rect: NSRect = .zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        if rect.height > 0, rect.origin.x.isFinite, rect.origin.y.isFinite {
            return rect
        }
        var actual = NSRange()
        let first = client.firstRect(
            forCharacterRange: NSRange(location: NSNotFound, length: 0),
            actualRange: &actual
        )
        if first.height > 0, first.origin.x.isFinite, first.origin.y.isFinite {
            return first
        }
        // 两者都失败时退回鼠标位置，至少让候选窗出现在用户视线附近
        let mouse = NSEvent.mouseLocation
        return NSRect(x: mouse.x, y: mouse.y - 20, width: 2, height: 20)
    }
}
