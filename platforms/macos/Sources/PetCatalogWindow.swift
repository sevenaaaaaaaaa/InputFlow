import AppKit

/// 「形象目录」窗口：列出可下载的 VRM 条目（含许可/来源），一键下载/删除；
/// 支持用户添加自己的来源（URL + 许可，下载后自动记录 sha256）。
final class PetCatalogWindowController: NSWindowController {
    static let shared = PetCatalogWindowController()

    private let store = EncryptedStore.shared
    private let listStack = NSStackView()
    private var entries: [PetCatalogEntry] = []
    private var downloading: Set<String> = []

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "InputFlow · 形象目录"
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

    private func buildUI() {
        guard let window else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 14, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "形象目录（VRM 3D 桌宠）")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        root.addArrangedSubview(title)

        let hint = NSTextField(wrappingLabelWithString:
            "只下载你信任且有权使用的模型；内置条目带 sha256 校验，自加来源会在首次下载后记录校验和。"
            + "所有下载都由你点击触发，应用不会后台上传或遥测。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 580
        root.addArrangedSubview(hint)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 8
        listStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        listStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: document.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        scroll.heightAnchor.constraint(equalToConstant: 420).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 584).isActive = true
        root.addArrangedSubview(scroll)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addArrangedSubview(button("添加来源…", #selector(addSource)))
        buttons.addArrangedSubview(button("打开目录文件", #selector(openCatalogFile)))
        buttons.addArrangedSubview(button("刷新", #selector(refreshAction)))
        root.addArrangedSubview(buttons)

        window.contentView = root
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor),
        ])
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    @objc private func refresh() {
        entries = PetCatalogStore.entries()
        listStack.arrangedSubviews.forEach {
            listStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let installed = Set(PluginStore.scan().packs.map(\.id))
        for entry in entries {
            listStack.addArrangedSubview(row(entry, installed: installed.contains(entry.id)))
        }
    }

    @objc private func refreshAction() { refresh() }

    private func row(_ entry: PetCatalogEntry, installed: Bool) -> NSView {
        let name = NSTextField(labelWithString: entry.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let meta = NSTextField(labelWithString:
            "\(entry.license) · \(entry.author ?? "未知作者") · \(entry.sizeText)"
            + ((entry.sha256 ?? "").isEmpty ? " · 无校验和（下载后记录）" : " · sha256 已校验"))
        meta.font = .systemFont(ofSize: 10.5)
        meta.textColor = .secondaryLabelColor
        let note = NSTextField(labelWithString: entry.note ?? "")
        note.font = .systemFont(ofSize: 10.5)
        note.textColor = .tertiaryLabelColor
        let text = NSStackView(views: [name, meta, note])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 6
        if installed {
            let use = NSButton(title: "使用", target: self, action: #selector(activateEntry(_:)))
            use.identifier = NSUserInterfaceItemIdentifier(entry.id)
            use.bezelStyle = .rounded
            let del = NSButton(title: "删除", target: self, action: #selector(deleteEntry(_:)))
            del.identifier = NSUserInterfaceItemIdentifier(entry.id)
            del.bezelStyle = .rounded
            actions.addArrangedSubview(use)
            actions.addArrangedSubview(del)
        } else {
            let dl = NSButton(
                title: downloading.contains(entry.id) ? "下载中…" : "下载",
                target: self,
                action: #selector(downloadEntry(_:))
            )
            dl.identifier = NSUserInterfaceItemIdentifier(entry.id)
            dl.bezelStyle = .rounded
            dl.isEnabled = !downloading.contains(entry.id)
            actions.addArrangedSubview(dl)
        }
        if let homepage = entry.homepage, let url = URL(string: homepage) {
            let open = NSButton(title: "主页", target: self, action: #selector(openHomepage(_:)))
            open.identifier = NSUserInterfaceItemIdentifier(homepage)
            open.bezelStyle = .rounded
            actions.addArrangedSubview(open)
            _ = url
        }

        let row = NSStackView(views: [text, NSView(), actions])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.widthAnchor.constraint(equalToConstant: 560).isActive = true
        return row
    }

    private func entry(for sender: NSButton) -> PetCatalogEntry? {
        guard let id = sender.identifier?.rawValue else { return nil }
        return entries.first { $0.id == id }
    }

    @objc private func downloadEntry(_ sender: NSButton) {
        guard let entry = entry(for: sender) else { return }
        downloading.insert(entry.id)
        refresh()
        PetModelInstaller.install(entry, onProgress: { _ in }) { [weak self] result in
            DispatchQueue.main.async {
                self?.downloading.remove(entry.id)
                switch result {
                case .success:
                    PetWindowController.shared.showToast("已下载：\(entry.name)", duration: 3)
                case .failure(let error):
                    PetWindowController.shared.showToast("下载失败：\(error.localizedDescription)", duration: 6)
                }
                self?.refresh()
            }
        }
    }

    @objc private func deleteEntry(_ sender: NSButton) {
        guard let entry = entry(for: sender) else { return }
        try? FileManager.default.removeItem(
            at: PluginStore.pluginsDir.appendingPathComponent(entry.id, isDirectory: true)
        )
        if PetWindowController.activePackId == entry.id {
            PetWindowController.activePackId = ""
        }
        refresh()
    }

    @objc private func activateEntry(_ sender: NSButton) {
        guard let entry = entry(for: sender) else { return }
        PetWindowController.activePackId = entry.id
        if !PetWindowController.isEnabled {
            PetWindowController.setEnabled(true)
        }
    }

    @objc private func openHomepage(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openCatalogFile() {
        let url = PetCatalogStore.userCatalogURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? PetCatalogStore.addUserEntry(
                PetCatalogEntry(id: "", name: "", url: "", sha256: nil, bytes: nil,
                                license: "", author: nil, homepage: nil, tags: nil, note: nil)
            )
            try? PetCatalogStore.removeUserEntry(id: "")
        }
        NSWorkspace.shared.open(url)
    }

    /// 添加来源：名称 / URL / 许可（sha256 可选，留空则首次下载后记录）。
    @objc private func addSource() {
        let alert = NSAlert()
        alert.messageText = "添加形象来源"
        alert.informativeText = "请填写你信任且有权使用的 VRM 直链地址（例如你自己导出或 CC0 分发页）。"
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 54, width: 360, height: 24))
        nameField.placeholderString = "名称，如：我的角色"
        let urlField = NSTextField(frame: NSRect(x: 0, y: 28, width: 360, height: 24))
        urlField.placeholderString = "VRM 直链（https://…）"
        let licenseField = NSTextField(frame: NSRect(x: 0, y: 2, width: 360, height: 24))
        licenseField.placeholderString = "许可，如 CC0-1.0 / VRM Public License 1.0"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 80))
        box.addSubview(nameField)
        box.addSubview(urlField)
        box.addSubview(licenseField)
        alert.accessoryView = box

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let license = licenseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: link), url.scheme == "https", !name.isEmpty else {
            PetWindowController.shared.showToast("请填写名称与 https 直链", duration: 5)
            return
        }
        let slug = "pet-custom-" + name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let entry = PetCatalogEntry(
            id: slug, name: name, url: link, sha256: nil, bytes: nil,
            license: license.isEmpty ? "未标注" : license,
            author: nil, homepage: nil, tags: ["custom"], note: "用户添加的来源"
        )
        do {
            try PetCatalogStore.addUserEntry(entry)
            refresh()
            PetWindowController.shared.showToast("已添加来源：\(name)（点「下载」开始）", duration: 4)
        } catch {
            PetWindowController.shared.showToast("保存失败：\(error.localizedDescription)", duration: 5)
        }
    }
}
