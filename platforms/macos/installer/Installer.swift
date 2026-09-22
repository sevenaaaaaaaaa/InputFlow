import AppKit
import Carbon

/// InputFlow 图形安装器：侧栏步骤向导（安装位置 → 配置 → 安装与验证）。
///
/// 签名说明：macOS 26+ 的输入源扫描器会拒绝 ad-hoc 签名的第三方输入法，
/// 必须 Developer ID 签名（并公证）才会出现在系统输入法列表；界面会给出诊断。
final class InstallerWindowController: NSWindowController {
    private let imeBundleID = "dev.inputflow.inputmethod"
    private let userAppPath = NSHomeDirectory() + "/Library/Input Methods/InputFlow.app"
    private let systemAppPath = "/Library/Input Methods/InputFlow.app"
    private let accent = NSColor.controlAccentColor

    // 侧栏
    private let stepBadges: [NSTextField]
    private let stepTitles: [NSTextField]

    // 页面
    private let pageContainer = NSStackView()
    private var pages: [NSView] = []
    private var step = 0
    private var installButton: NSButton?

    // 配置控件
    private let modePopup = NSPopUpButton()
    private let traditionalCheck = NSButton(checkboxWithTitle: "输出繁体汉字（简繁转换）", target: nil, action: nil)
    private let clipboardCheck = NSButton(checkboxWithTitle: "记录剪切板历史（默认关闭，加密保存）", target: nil, action: nil)
    private let petCheck = NSButton(checkboxWithTitle: "开启桌宠模式", target: nil, action: nil)
    private let appMemoryCheck = NSButton(checkboxWithTitle: "按应用记忆中英文输入状态", target: nil, action: nil)
    private let statsCheck = NSButton(checkboxWithTitle: "输入统计（仅本地）", target: nil, action: nil)
    private let halfPunctCheck = NSButton(checkboxWithTitle: "所有应用都强制半角标点", target: nil, action: nil)

    // 安装位置卡片
    private let userCard = OptionCard(title: "仅当前用户", subtitle: "~/Library/Input Methods · 无需管理员密码")
    private let systemCard = OptionCard(title: "所有用户", subtitle: "/Library/Input Methods · 需要管理员授权")
    private var installSystemWide = false

    // 页脚 / 状态
    private let backButton = NSButton(title: "上一步", target: nil, action: nil)
    private let nextButton = NSButton(title: "下一步", target: nil, action: nil)
    private let signaturePill = NSTextField(labelWithString: "")
    private let detectPill = NSTextField(labelWithString: "未检测")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let statusText = NSTextView()
    private let purgeCheck = NSButton(checkboxWithTitle: "同时删除用户数据与钥匙串密钥", target: nil, action: nil)
    private var progressTimer: Timer?
    private var pollCount = 0
    private var hasInstalled = false

    private let modeOptions: [(String, String)] = [
        ("pinyin", "拼音（全拼，推荐）"),
        ("flypy", "小鹤双拼"),
        ("mspy", "微软双拼"),
        ("zrm", "自然码"),
        ("en", "English"),
        ("ja", "日本語"),
    ]

    init() {
        stepBadges = (0..<3).map { _ in NSTextField(labelWithString: "") }
        stepTitles = (0..<3).map { _ in NSTextField(labelWithString: "") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "InputFlow 安装器"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildUI()
        switchStep(0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    // MARK: - 布局

    private func buildUI() {
        guard let window else { return }
        userCard.setSelected(true)
        userCard.onSelect = { [weak self] in self?.selectLocation(system: false) }
        systemCard.onSelect = { [weak self] in self?.selectLocation(system: true) }

        let root = NSStackView()
        root.orientation = .horizontal
        root.spacing = 0
        root.distribution = .fill
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        root.addArrangedSubview(buildSidebar())
        root.addArrangedSubview(buildContent())
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])
        refreshSignature()
    }

    private func buildSidebar() -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.widthAnchor.constraint(equalToConstant: 232).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 52, left: 20, bottom: 20, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)

        let icon = NSImageView()
        icon.image = NSImage(named: "InputFlow") ?? NSImage(named: NSImage.applicationIconName)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let name = NSTextField(labelWithString: "InputFlow")
        name.font = .systemFont(ofSize: 16, weight: .semibold)
        let version = NSTextField(labelWithString: "本地输入法 · v0.1.0")
        version.font = .systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor
        let header = NSStackView(views: [icon, name, version])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(22, after: header)

        let titles = ["安装位置", "输入与隐私", "安装与验证"]
        for (index, title) in titles.enumerated() {
            let badge = stepBadges[index]
            badge.stringValue = "\(index + 1)"
            badge.alignment = .center
            badge.font = .systemFont(ofSize: 11, weight: .bold)
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 10
            badge.widthAnchor.constraint(equalToConstant: 20).isActive = true
            badge.heightAnchor.constraint(equalToConstant: 20).isActive = true

            let label = stepTitles[index]
            label.stringValue = title
            label.font = .systemFont(ofSize: 13, weight: .medium)

            let row = NSStackView(views: [badge, label])
            row.orientation = .horizontal
            row.spacing = 10
            stack.addArrangedSubview(row)
        }
        return effect
    }

    private func buildContent() -> NSView {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 52, left: 26, bottom: 20, right: 26)
        content.translatesAutoresizingMaskIntoConstraints = false

        pageContainer.orientation = .vertical
        pageContainer.alignment = .leading
        pageContainer.spacing = 0
        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.widthAnchor.constraint(equalToConstant: 460).isActive = true
        pages = [buildLocationPage(), buildConfigPage(), buildInstallPage()]
        for page in pages {
            page.translatesAutoresizingMaskIntoConstraints = false
            page.widthAnchor.constraint(equalToConstant: 460).isActive = true
            pageContainer.addArrangedSubview(page)
        }
        content.addArrangedSubview(pageContainer)
        pageContainer.heightAnchor.constraint(equalToConstant: 372).isActive = true

        // 页脚
        let spacer = NSView()
        let footer = NSStackView(views: [signaturePill, spacer, backButton, nextButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.alignment = .centerY
        footer.widthAnchor.constraint(equalToConstant: 460).isActive = true
        signaturePill.font = .systemFont(ofSize: 11)
        signaturePill.wantsLayer = true
        signaturePill.layer?.cornerRadius = 8
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.bezelStyle = .rounded
        nextButton.target = self
        nextButton.action = #selector(goNext)
        nextButton.bezelStyle = .rounded
        content.addArrangedSubview(footer)
        return content
    }

    // MARK: - 页面

    private func pageTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 19, weight: .semibold)
        return label
    }

    private func buildLocationPage() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.addArrangedSubview(pageTitle("选择安装位置"))
        let hint = NSTextField(wrappingLabelWithString:
            "系统级安装需要管理员授权；两种方式都会写入你的配置并注册输入法。")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 460
        stack.addArrangedSubview(hint)
        stack.setCustomSpacing(16, after: hint)
        userCard.widthAnchor.constraint(equalToConstant: 460).isActive = true
        systemCard.widthAnchor.constraint(equalToConstant: 460).isActive = true
        stack.addArrangedSubview(userCard)
        stack.addArrangedSubview(systemCard)
        return stack
    }

    private func buildConfigPage() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.addArrangedSubview(pageTitle("输入与隐私"))

        modePopup.addItems(withTitles: modeOptions.map { $0.1 })
        modePopup.selectItem(at: 0)
        traditionalCheck.state = .off
        clipboardCheck.state = .off
        petCheck.state = .off
        appMemoryCheck.state = .on
        statsCheck.state = .on
        halfPunctCheck.state = .off

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 0
        form.addArrangedSubview(formRow("默认输入模式", modePopup))
        for check in [traditionalCheck, clipboardCheck, petCheck, appMemoryCheck, statsCheck, halfPunctCheck] {
            form.addArrangedSubview(formRow(nil, check))
        }
        stack.addArrangedSubview(card(form))
        return stack
    }

    private func buildInstallPage() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.addArrangedSubview(pageTitle("安装与验证"))

        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.preferredMaxLayoutWidth = 440
        summaryLabel.stringValue = summaryText()
        stack.addArrangedSubview(card(summaryLabel))

        let installRow = NSStackView()
        installRow.orientation = .horizontal
        installRow.spacing = 8
        let installButton = NSButton(title: "开始安装", target: self, action: #selector(install))
        installButton.bezelStyle = .rounded
        installButton.bezelColor = accent
        self.installButton = installButton
        let detectButton = NSButton(title: "检测收录", target: self, action: #selector(checkRegistration))
        detectButton.bezelStyle = .rounded
        let settingsButton = NSButton(title: "打开键盘设置", target: self, action: #selector(openKeyboardSettings))
        settingsButton.bezelStyle = .rounded
        installRow.addArrangedSubview(installButton)
        installRow.addArrangedSubview(detectButton)
        installRow.addArrangedSubview(settingsButton)
        stack.addArrangedSubview(installRow)

        detectPill.font = .systemFont(ofSize: 11, weight: .medium)
        detectPill.wantsLayer = true
        detectPill.layer?.cornerRadius = 8
        detectPill.alignment = .center
        detectPill.widthAnchor.constraint(equalToConstant: 220).isActive = true
        stack.addArrangedSubview(detectPill)
        setDetectPill("未检测", color: .tertiaryLabelColor)

        let logScroll = NSScrollView()
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .noBorder
        logScroll.drawsBackground = false
        statusText.isEditable = false
        statusText.drawsBackground = false
        statusText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusText.textContainerInset = NSSize(width: 10, height: 10)
        statusText.string = "点击「开始安装」后，这里会显示进度与结果。\n"
        logScroll.documentView = statusText
        logScroll.widthAnchor.constraint(equalToConstant: 452).isActive = true
        logScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        stack.addArrangedSubview(card(logScroll))

        let uninstallRow = NSStackView()
        uninstallRow.orientation = .horizontal
        uninstallRow.spacing = 8
        let uninstallButton = NSButton(title: "卸载 InputFlow", target: self, action: #selector(uninstall))
        uninstallButton.bezelStyle = .rounded
        uninstallRow.addArrangedSubview(uninstallButton)
        uninstallRow.addArrangedSubview(purgeCheck)
        stack.addArrangedSubview(uninstallRow)
        return stack
    }

    // MARK: - 小组件

    private func formRow(_ title: String?, _ control: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        let label = NSTextField(labelWithString: title ?? "")
        label.font = .systemFont(ofSize: 13)
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true
        row.addArrangedSubview(label)
        row.addArrangedSubview(control)
        row.widthAnchor.constraint(equalToConstant: 436).isActive = true
        return row
    }

    private func card(_ content: NSView) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -4),
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: 4),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -4),
        ])
        box.widthAnchor.constraint(equalToConstant: 460).isActive = true
        return box
    }

    private func switchStep(_ index: Int) {
        step = index
        for (i, page) in pages.enumerated() {
            page.isHidden = i != index
        }
        for (i, badge) in stepBadges.enumerated() {
            let active = i <= index
            badge.textColor = active ? .white : .secondaryLabelColor
            badge.layer?.backgroundColor = (active ? accent : NSColor.quaternaryLabelColor).cgColor
            stepTitles[i].textColor = i == index ? .labelColor : .secondaryLabelColor
            stepTitles[i].font = .systemFont(ofSize: 13, weight: i == index ? .semibold : .medium)
        }
        backButton.isHidden = index == 0
        nextButton.title = index == 2 ? "完成" : "下一步"
        nextButton.keyEquivalent = "\r"
        if index == 2 {
            summaryLabel.stringValue = summaryText()
        }
    }

    @objc private func goBack() {
        switchStep(max(0, step - 1))
    }

    @objc private func goNext() {
        if step == 2 {
            window?.close()
            NSApp.terminate(nil)
            return
        }
        if step == 1 {
            saveConfig()
        }
        switchStep(step + 1)
    }

    private func selectLocation(system: Bool) {
        installSystemWide = system
        userCard.setSelected(!system)
        systemCard.setSelected(system)
        summaryLabel.stringValue = summaryText()
    }

    private func summaryText() -> String {
        let location = installSystemWide ? "/Library/Input Methods（所有用户）" : "~/Library/Input Methods（当前用户）"
        let mode = modeOptions[modePopup.indexOfSelectedItem].1
        return "安装位置：\(location)\n默认模式：\(mode) · 繁体：\(onOff(traditionalCheck)) · "
            + "剪切板：\(onOff(clipboardCheck)) · 桌宠：\(onOff(petCheck))"
    }

    private func onOff(_ button: NSButton) -> String {
        button.state == .on ? "开" : "关"
    }

    // MARK: - 配置

    @objc private func saveConfig() {
        let mode = modeOptions[modePopup.indexOfSelectedItem].0
        let defaults = UserDefaults(suiteName: imeBundleID)
        defaults?.set(mode, forKey: "InputFlowMode")
        if mode != "en" && mode != "ja" {
            defaults?.set(mode, forKey: "InputFlowLastChineseMode")
        }
        defaults?.set(traditionalCheck.state == .on, forKey: "InputFlowTraditional")
        defaults?.set(clipboardCheck.state == .on, forKey: "InputFlowClipboardEnabled")
        defaults?.set(petCheck.state == .on, forKey: "InputFlowPetEnabled")
        defaults?.set(appMemoryCheck.state == .on, forKey: "InputFlowAppModeMemoryEnabled")
        defaults?.set(statsCheck.state == .on, forKey: "InputFlowStatsEnabled")
        defaults?.set(halfPunctCheck.state == .on, forKey: "InputFlowForceHalfPunctuation")
        defaults?.synchronize()
        log("已保存配置：模式=\(mode) · 繁体=\(onOff(traditionalCheck)) · 剪切板=\(onOff(clipboardCheck)) · 桌宠=\(onOff(petCheck))")
    }

    // MARK: - 签名诊断

    private var sourceApp: String {
        Bundle.main.resourcePath.map { $0 + "/InputFlow.app" } ?? ""
    }

    private var sourceDict: String {
        Bundle.main.resourcePath.map { $0 + "/base.ifd" } ?? ""
    }

    private var userDataDir: String {
        NSHomeDirectory() + "/Library/Application Support/InputFlow"
    }

    private func refreshSignature() {
        let info = runShell("/usr/bin/codesign -dv --verbose=4 \"\(sourceApp)\" 2>&1")
        let adhoc = info.contains("Signature=adhoc")
        if adhoc {
            signaturePill.stringValue = "  签名：ad-hoc · 系统不会收录，需 Developer ID  "
            signaturePill.textColor = .systemOrange
            signaturePill.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.14).cgColor
        } else {
            signaturePill.stringValue = "  签名：有效 · 安装后应可被系统收录  "
            signaturePill.textColor = .systemGreen
            signaturePill.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.14).cgColor
        }
    }

    private func setDetectPill(_ text: String, color: NSColor) {
        detectPill.stringValue = "  收录状态：\(text)  "
        detectPill.textColor = color
        detectPill.layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
    }

    // MARK: - 安装

    @objc private func install() {
        saveConfig()
        if installSystemWide {
            installSystem()
        } else {
            installForUser()
        }
    }

    private func installForUser() {
        let fm = FileManager.default
        do {
            let dest = userAppPath
            try fm.createDirectory(atPath: userDataDir, withIntermediateDirectories: true)
            try? fm.removeItem(atPath: dest)
            try fm.createDirectory(atPath: NSHomeDirectory() + "/Library/Input Methods", withIntermediateDirectories: true)
            try fm.copyItem(atPath: sourceApp, toPath: dest)
            if fm.fileExists(atPath: sourceDict) {
                try? fm.removeItem(atPath: userDataDir + "/base.ifd")
                try fm.copyItem(atPath: sourceDict, toPath: userDataDir + "/base.ifd")
            }
            runShell("/usr/bin/xattr -dr com.apple.quarantine \"\(dest)\"")
            runShell("/usr/bin/killall InputFlow")
            runShell("\"\(dest)/Contents/MacOS/InputFlow\" --register-input-source")
            runShell("\"\(dest)/Contents/MacOS/InputFlow\" --enable-input-source")
            runShell("/usr/bin/killall TextInputMenuAgent imklaunchagent")
            hasInstalled = true
            log("✅ 已安装到 \(dest)")
            schedulePoll()
        } catch {
            log("❌ 用户级安装失败：\(error.localizedDescription)")
        }
    }

    private func installSystem() {
        let user = NSUserName()
        let script = """
        #!/bin/bash
        set -e
        SRC="\(sourceApp)"
        DST="/Library/Input Methods/InputFlow.app"
        DICT_SRC="\(sourceDict)"
        DICT_DST="/Users/\(user)/Library/Application Support/InputFlow"
        mkdir -p "/Library/Input Methods"
        rm -rf "$DST"
        cp -R "$SRC" "$DST"
        chown -R root:wheel "$DST"
        chmod -R go-w "$DST"
        xattr -dr com.apple.quarantine "$DST" 2>/dev/null || true
        mkdir -p "$DICT_DST"
        if [ -f "$DICT_SRC" ]; then cp "$DICT_SRC" "$DICT_DST/base.ifd"; chown \(user) "$DICT_DST/base.ifd" || true; fi
        "$DST/Contents/MacOS/InputFlow" --register-input-source || true
        "$DST/Contents/MacOS/InputFlow" --enable-input-source || true
        """
        let path = NSTemporaryDirectory() + "inputflow-install.sh"
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            log("❌ 无法写入安装脚本：\(error.localizedDescription)")
            return
        }
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"/bin/bash \(path)\" with administrator privileges")?
            .executeAndReturnError(&error)
        if let error {
            log("❌ 系统级安装失败或已取消：\(error[NSAppleScript.errorMessage] ?? error)")
            return
        }
        runShell("/usr/bin/killall TextInputMenuAgent imklaunchagent")
        hasInstalled = true
        log("✅ 已安装到 \(systemAppPath)")
        schedulePoll()
    }

    // MARK: - 收录检测

    @objc private func checkRegistration() {
        let installed = [userAppPath, systemAppPath].filter { FileManager.default.fileExists(atPath: $0) }
        log("安装状态：\(installed.isEmpty ? "未安装" : installed.joined(separator: "、"))")
        if isRegistered() {
            log("✅ 系统已收录 InputFlow（可在 系统设置 → 键盘 → 文字输入 → 输入法 中添加）")
            setDetectPill("已收录", color: .systemGreen)
            progressTimer?.invalidate()
        } else {
            log("⏳ 系统暂未收录。若签名为 ad-hoc，这是预期结果；有效签名可注销重登后再试。")
            setDetectPill("未收录", color: .systemOrange)
        }
    }

    private func schedulePoll() {
        progressTimer?.invalidate()
        pollCount = 0
        setDetectPill("检测中…", color: .systemBlue)
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pollCount += 1
            if self.isRegistered() {
                self.log("✅ 系统已收录 InputFlow")
                self.setDetectPill("已收录", color: .systemGreen)
                self.progressTimer?.invalidate()
            } else if self.pollCount >= 20 {
                self.log("⏳ 等待超时：系统未收录（ad-hoc 签名被拒属预期；有效签名请注销重登）")
                self.setDetectPill("未收录", color: .systemOrange)
                self.progressTimer?.invalidate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func isRegistered() -> Bool {
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
            return false
        }
        for source in list {
            guard let idRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let id = unsafeBitCast(idRef, to: CFString.self) as String
            if id.hasPrefix(imeBundleID) {
                return true
            }
        }
        return false
    }

    // MARK: - 卸载

    @objc private func uninstall() {
        let purge = purgeCheck.state == .on
        runShell("/usr/bin/killall InputFlow")
        for path in [userAppPath, systemAppPath] where FileManager.default.fileExists(atPath: path) {
            if path.hasPrefix("/Library") {
                let tmp = NSTemporaryDirectory() + "inputflow-uninstall.sh"
                try? "#!/bin/bash\nrm -rf \"\(path)\"\n".write(toFile: tmp, atomically: true, encoding: .utf8)
                var error: NSDictionary?
                NSAppleScript(source: "do shell script \"/bin/bash \(tmp)\" with administrator privileges")?
                    .executeAndReturnError(&error)
                if error != nil { log("❌ 系统级卸载失败或已取消") }
            } else {
                try? FileManager.default.removeItem(atPath: path)
            }
            log("已移除 \(path)")
        }
        if purge {
            UserDefaults(suiteName: imeBundleID)?.removePersistentDomain(forName: imeBundleID)
            runShell("/usr/bin/security delete-generic-password -s \(imeBundleID) -a userdata-key")
            try? FileManager.default.removeItem(atPath: userDataDir)
            log("已删除用户数据与钥匙串密钥")
        }
        setDetectPill("未检测", color: .tertiaryLabelColor)
        checkRegistration()
    }

    // MARK: - 其他

    @objc private func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 离屏快照（`InputFlowInstaller --snapshot <前缀>`），用于开发时检查界面。
    func snapshotStep(_ index: Int, to path: String) {
        switchStep(index)
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private func log(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusText.string += text + "\n"
            self.statusText.scrollToEndOfDocument(nil)
        }
    }

    @discardableResult
    private func runShell(_ command: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "运行失败: \(error.localizedDescription)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// 可点选的安装位置卡片。
final class OptionCard: NSView {
    var onSelect: (() -> Void)?
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private var selected = false
    private let accent = NSColor.controlAccentColor

    init(title: String, subtitle: String) {
        titleLabel = NSTextField(labelWithString: title)
        subtitleLabel = NSTextField(labelWithString: subtitle)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1.5
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    func setSelected(_ on: Bool) {
        selected = on
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.borderColor = (selected ? accent : NSColor.separatorColor).cgColor
        layer?.backgroundColor = (selected ? accent.withAlphaComponent(0.10) : NSColor.controlBackgroundColor.withAlphaComponent(0.5)).cgColor
    }
}

@main
struct InstallerApp {
    static func main() {
        let app = NSApplication.shared
        let args = CommandLine.arguments
        if args.count > 2, args[1] == "--snapshot" {
            app.setActivationPolicy(.accessory)
            let controller = InstallerWindowController()
            controller.showWindow(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            for step in 0..<3 {
                controller.snapshotStep(step, to: "\(args[2])-\(step).png")
            }
            exit(0)
        }
        app.setActivationPolicy(.regular)
        let controller = InstallerWindowController()
        controller.showWindow(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}
