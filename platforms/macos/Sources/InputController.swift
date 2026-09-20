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
    }

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
        let clipItem = NSMenuItem(title: "剪切板历史", action: nil, keyEquivalent: "")
        clipItem.submenu = clipboardSubmenu()
        menu.addItem(clipItem)
        let ai = NSMenuItem(title: "AI 增强…", action: #selector(openAISettings(_:)), keyEquivalent: "")
        ai.target = self
        menu.addItem(ai)
        let prefs = NSMenuItem(title: "打开词典目录…", action: #selector(openDictionaryFolder(_:)), keyEquivalent: "")
        prefs.target = self
        menu.addItem(prefs)
        return menu
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

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard
            let id = sender.representedObject as? String,
            let mode = InputFlowMode(rawValue: id)
        else { return }
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
            guard engine.hasComposition else { return false }
            select(index: page * CandidateWindowController.pageSize, client: client)
            return true
        default:
            break
        }

        if engine.hasComposition {
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

        // 中文模式下的标点映射（未组合时）：`,。？！；：、（）【】《》“”‘’…
        let mode = InputFlowMode(rawValue: engine.mode) ?? .pinyin
        if !engine.hasComposition, mode.usesChinesePunctuation, let punct = chinesePunctuation(chars) {
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
        page = 0
        update(client)
    }

    /// 把会话内学到的用户词（含上下词二元组）合并进加密存储。
    private func persistUserModel() {
        store.mergeUserModel(tsv: engine.exportUserModel())
    }

    private func update(_ client: IMKTextInput) {
        let comp = engine.composition
        guard !comp.raw.isEmpty else {
            clearMarkedText(client)
            window.hide()
            return
        }
        let display = comp.preedit.isEmpty ? comp.raw : comp.preedit
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
        var rect: NSRect = .zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        return rect.height > 0 ? rect : nil
    }
}
