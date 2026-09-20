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

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        if !store.userModelTsv.isEmpty {
            _ = engine.importUserModel(store.userModelTsv)
        }
        engine.setTraditional(UserDefaults.standard.bool(forKey: Self.traditionalKey))
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
        let clipItem = NSMenuItem(title: "剪切板历史", action: nil, keyEquivalent: "")
        clipItem.submenu = clipboardSubmenu()
        menu.addItem(clipItem)
        let trad = NSMenuItem(title: "繁体输出", action: #selector(toggleTraditional(_:)), keyEquivalent: "")
        trad.target = self
        trad.state = engine.isTraditional ? .on : .off
        menu.addItem(trad)
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

    /// 当前前台应用画像（代码/浏览器/聊天），决定标点与手势能力。
    private var profile: AppProfile {
        let bundleId = currentClient?.bundleIdentifier() ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return AppProfile.make(bundleId: bundleId)
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
        window.hide()
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

        let flags = event.modifierFlags
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            return false
        }

        let keyCode = event.keyCode

        switch keyCode {
        case 53: // Esc
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
            guard engine.hasComposition, let raw = engine.commitRaw() else { return false }
            commit(raw, client: client)
            return true
        case 51: // Delete
            guard engine.hasComposition else { return false }
            _ = engine.backspace()
            update(client)
            return true
        case 49: // Space
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

        guard let chars = event.charactersIgnoringModifiers else { return false }

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
        for ch in chars {
            if engine.feed(ch) {
                accepted = true
            } else {
                break
            }
        }
        if accepted {
            page = 0
            update(client)
        }
        return accepted
    }

    override func commitComposition(_ sender: Any!) {
        if let client = sender as? IMKTextInput, let raw = engine.commitRaw() {
            client.insertText(raw, replacementRange: NSRange(location: NSNotFound, length: 0))
            persistUserModel()
        }
        window.hide()
    }

    override func deactivateServer(_ sender: Any!) {
        engine.clear()
        urlMode = false
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
        page = 0
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
        guard let text = engine.select(index) else {
            NSSound.beep()
            return
        }
        commit(text, client: client)
    }

    private func commit(_ text: String, client: IMKTextInput) {
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
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
            clearMarkedText(client)
            window.hide()
            PetWindowController.shared.react(.idle)
            return
        }
        PetWindowController.shared.react(comp.raw.isEmpty ? .idle : .composing)
        let display = comp.preedit.isEmpty ? comp.raw : comp.preedit
        if display.isEmpty {
            // 表情模式的精选列表：不产生预编辑串，只展示候选窗
            clearMarkedText(client)
        } else {
            let attributes: [NSAttributedString.Key: Any] = [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: NSColor.secondaryLabelColor,
                .foregroundColor: NSColor.labelColor,
            ]
            let marked = NSAttributedString(string: display, attributes: attributes)
            client.setMarkedText(
                marked,
                selectionRange: NSRange(location: marked.length, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
        }
        let caret = caretRect(client)
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
        // 首选 firstRect（更标准），失败再退回 attributes 行高矩形。
        var actual = NSRange()
        let first = client.firstRect(
            forCharacterRange: NSRange(location: NSNotFound, length: 0),
            actualRange: &actual
        )
        if first.height > 0 {
            return first
        }
        var rect: NSRect = .zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        return rect.height > 0 ? rect : nil
    }
}
