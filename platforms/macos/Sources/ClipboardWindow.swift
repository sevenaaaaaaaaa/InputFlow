import AppKit

/// 剪切板历史窗：搜索、复制、删除、一键清空，以及总开关（默认关闭）。
final class ClipboardWindowController: NSWindowController {
    static let shared = ClipboardWindowController()

    private let store = EncryptedStore.shared
    private let monitor = ClipboardMonitor.shared
    private let table = NSTableView()
    private let searchField = NSSearchField()
    private let toggle = NSButton(checkboxWithTitle: "记录剪切板（默认关闭，仅本机加密保存）", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private var items: [ClipboardItem] = []

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "InputFlow · 剪切板历史"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildUI()
    }

    func show() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let window else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 14, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false

        toggle.state = monitor.isEnabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggleRecording(_:))
        root.addArrangedSubview(toggle)

        searchField.placeholderString = "搜索历史…"
        searchField.target = self
        searchField.action = #selector(reload)
        searchField.widthAnchor.constraint(equalToConstant: 484).isActive = true
        root.addArrangedSubview(searchField)

        table.headerView = nil
        table.rowHeight = 44
        table.usesAlternatingRowBackgroundColors = false
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(copySelected(_:))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.widthAnchor.constraint(equalToConstant: 484).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 400).isActive = true
        root.addArrangedSubview(scroll)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addArrangedSubview(button("复制选中", #selector(copySelected(_:))))
        buttons.addArrangedSubview(button("删除选中", #selector(deleteSelected(_:))))
        buttons.addArrangedSubview(button("清空历史", #selector(clearAll(_:))))
        root.addArrangedSubview(buttons)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(statusLabel)

        let note = NSTextField(wrappingLabelWithString:
            "历史加密保存在 ~/Library/Application Support/InputFlow/userdata.enc，"
            + "密码管理器标记的敏感内容不会记录。")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.preferredMaxLayoutWidth = 484
        root.addArrangedSubview(note)

        window.contentView = root
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reload),
            name: .inputFlowClipboardChanged,
            object: nil
        )
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    @objc private func reload() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        items = store.clipboard.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
        table.reloadData()
        statusLabel.stringValue = "共 \(store.clipboard.count) 条 · 显示 \(items.count) 条"
    }

    @objc private func toggleRecording(_ sender: NSButton) {
        monitor.setEnabled(sender.state == .on)
    }

    @objc private func copySelected(_ sender: Any) {
        let row = table.selectedRow
        guard items.indices.contains(row) else { return }
        copy(items[row])
    }

    private func copy(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
        monitor.ignore(item.text)
        statusLabel.stringValue = "已复制，按 ⌘V 粘贴 · \(Self.relative(item.createdAt))"
        window?.close()
    }

    @objc private func deleteSelected(_ sender: Any) {
        let row = table.selectedRow
        guard items.indices.contains(row) else { return }
        store.removeClipboard(items[row])
        reload()
    }

    @objc private func clearAll(_ sender: Any) {
        store.clearClipboard()
        reload()
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

extension ClipboardWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let item = items[row]

        let text = NSTextField(labelWithString: item.text.split(separator: "\n").first.map(String.init) ?? item.text)
        text.font = .systemFont(ofSize: 13)
        text.lineBreakMode = .byTruncatingTail

        let meta = NSTextField(labelWithString:
            "\(Self.relative(item.createdAt)) · \(item.text.count) 字")
        meta.font = .systemFont(ofSize: 10)
        meta.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [text, meta])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {}
}
