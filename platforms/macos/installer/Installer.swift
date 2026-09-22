import AppKit
import Carbon

/// InputFlow 图形安装器：引导 + 配置 + 安装 + 收录检测 + 卸载。
///
/// 说明（ADR/实测）：macOS 26+ 的输入源扫描器会拒绝 ad-hoc 签名的第三方输入法，
/// 必须使用 Developer ID 签名（并公证）才会出现在系统输入法列表。安装器会检测
/// 内嵌的 InputFlow.app 签名状态并在首页给出明确诊断。
final class InstallerWindowController: NSWindowController {
    private let imeBundleID = "dev.inputflow.inputmethod"
    private let userAppPath = NSHomeDirectory() + "/Library/Input Methods/InputFlow.app"
    private let systemAppPath = "/Library/Input Methods/InputFlow.app"

    // 配置控件
    private let modePopup = NSPopUpButton()
    private let traditionalCheck = NSButton(checkboxWithTitle: "输出繁体汉字（简繁转换）", target: nil, action: nil)
    private let clipboardCheck = NSButton(checkboxWithTitle: "记录剪切板历史（默认关闭，加密保存）", target: nil, action: nil)
    private let petCheck = NSButton(checkboxWithTitle: "开启桌宠模式", target: nil, action: nil)
    private let appMemoryCheck = NSButton(checkboxWithTitle: "按应用记忆中英文输入状态", target: nil, action: nil)
    private let statsCheck = NSButton(checkboxWithTitle: "输入统计（仅本地）", target: nil, action: nil)
    private let halfPunctCheck = NSButton(checkboxWithTitle: "所有应用都强制半角标点", target: nil, action: nil)
    private let locationPopup = NSPopUpButton()

    // 状态
    private let statusText = NSTextView()
    private let sigLabel = NSTextField(wrappingLabelWithString: "")
    private var progressTimer: Timer?
    private var pollCount = 0

    private let modeOptions: [(String, String)] = [
        ("pinyin", "拼音（全拼，推荐）"),
        ("flypy", "小鹤双拼"),
        ("mspy", "微软双拼"),
        ("zrm", "自然码"),
        ("en", "English"),
        ("ja", "日本語"),
    ]

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "InputFlow 安装器"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    // MARK: - UI

    private func buildUI() {
        guard let window else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 18, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "InputFlow 安装向导")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        root.addArrangedSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString:
            "隐私优先的本地输入法：引擎、词库、学习全部在本机，零服务器、零遥测。"
            + "安装会写入配置并尝试注册输入法。")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = 600
        root.addArrangedSubview(subtitle)

        root.addArrangedSubview(section("① 安装位置"))
        locationPopup.addItems(withTitles: [
            "仅当前用户（~/Library/Input Methods，无需密码）",
            "所有用户（/Library/Input Methods，需要管理员密码）",
        ])
        locationPopup.selectItem(at: 0)
        root.addArrangedSubview(locationPopup)

        root.addArrangedSubview(section("② 输入与隐私配置"))
        modePopup.addItems(withTitles: modeOptions.map { $0.1 })
        modePopup.selectItem(at: 0)
        let modeRow = NSStackView(views: [NSTextField(labelWithString: "默认输入模式："), modePopup])
        modeRow.orientation = .horizontal
        modeRow.spacing = 8
        root.addArrangedSubview(modeRow)

        traditionalCheck.state = .off
        clipboardCheck.state = .off
        petCheck.state = .off
        appMemoryCheck.state = .on
        statsCheck.state = .on
        halfPunctCheck.state = .off
        for check in [traditionalCheck, clipboardCheck, petCheck, appMemoryCheck, statsCheck, halfPunctCheck] {
            root.addArrangedSubview(check)
        }

        root.addArrangedSubview(section("③ 签名诊断"))
        sigLabel.font = .systemFont(ofSize: 11)
        sigLabel.preferredMaxLayoutWidth = 600
        root.addArrangedSubview(sigLabel)

        root.addArrangedSubview(section("④ 安装与收录检测"))
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addArrangedSubview(button("保存配置", #selector(saveConfig)))
        buttons.addArrangedSubview(button("安装 InputFlow", #selector(install)))
        buttons.addArrangedSubview(button("检测收录状态", #selector(checkRegistration)))
        buttons.addArrangedSubview(button("打开键盘设置", #selector(openKeyboardSettings)))
        root.addArrangedSubview(buttons)

        let uninstallRow = NSStackView()
        uninstallRow.orientation = .horizontal
        uninstallRow.spacing = 8
        uninstallRow.addArrangedSubview(button("卸载 InputFlow", #selector(uninstall)))
        let purgeCheck = NSButton(checkboxWithTitle: "同时删除用户数据与钥匙串密钥", target: nil, action: nil)
        purgeCheck.identifier = NSUserInterfaceItemIdentifier("purge")
        uninstallRow.addArrangedSubview(purgeCheck)
        root.addArrangedSubview(uninstallRow)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = statusText
        statusText.isEditable = false
        statusText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusText.string = ""
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 612).isActive = true
        root.addArrangedSubview(scroll)

        window.contentView = root
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor),
        ])

        refreshSignatureDiagnosis()
        checkRegistration()
    }

    private func section(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    // MARK: - 路径

    private var sourceApp: String {
        Bundle.main.resourcePath.map { $0 + "/InputFlow.app" } ?? ""
    }

    private var sourceDict: String {
        Bundle.main.resourcePath.map { $0 + "/base.ifd" } ?? ""
    }

    private var userDataDir: String {
        NSHomeDirectory() + "/Library/Application Support/InputFlow"
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
        log("已保存配置：模式=\(mode)，繁体=\(onOff(traditionalCheck))，剪切板=\(onOff(clipboardCheck))，桌宠=\(onOff(petCheck))")
    }

    private func onOff(_ button: NSButton) -> String {
        button.state == .on ? "开" : "关"
    }

    // MARK: - 签名诊断

    private func refreshSignatureDiagnosis() {
        let info = runShell("/usr/bin/codesign -dv --verbose=4 \"\(sourceApp)\" 2>&1")
        let adhoc = info.contains("Signature=adhoc")
        let team = info.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }).map(String.init) ?? "TeamIdentifier=?"
        var text = "当前安装包内 InputFlow.app 的签名：\(adhoc ? "ad-hoc（无开发者身份）" : "有效签名") · \(team)\n"
        if adhoc {
            text += "⚠️ macOS 26 及以上会拒绝收录 ad-hoc 签名的第三方输入法（实测：同目录下 Developer ID 签名的鼠须管可即时收录，ad-hoc 版不收录）。\n"
            text += "安装流程仍会执行，但系统输入法列表里不会出现 InputFlow；需要 Developer ID 签名（并公证）后重新打包。"
            sigLabel.textColor = .systemOrange
        } else {
            text += "签名有效，安装后应能被系统收录。"
            sigLabel.textColor = .systemGreen
        }
        sigLabel.stringValue = text
    }

    // MARK: - 安装

    @objc private func install() {
        saveConfig()
        if locationPopup.indexOfSelectedItem == 1 {
            installSystemWide()
        } else {
            installForUser()
        }
    }

    private func installForUser() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: userDataDir, withIntermediateDirectories: true)
            let dest = NSHomeDirectory() + "/Library/Input Methods/InputFlow.app"
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
            log("✅ 已安装到 \(dest)")
            schedulePoll()
        } catch {
            log("❌ 用户级安装失败：\(error.localizedDescription)")
        }
    }

    private func installSystemWide() {
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
        let apple = "do shell script \"/bin/bash \(path)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: apple)?.executeAndReturnError(&error)
        if let error {
            log("❌ 系统级安装失败或已取消：\(error[NSAppleScript.errorMessage] ?? error)")
            return
        }
        runShell("/usr/bin/killall TextInputMenuAgent imklaunchagent")
        log("✅ 已安装到 \(systemAppPath)")
        schedulePoll()
    }

    // MARK: - 收录检测

    @objc private func checkRegistration() {
        let paths = [userAppPath, systemAppPath]
        let installed = paths.filter { FileManager.default.fileExists(atPath: $0) }
        log("安装状态：\(installed.isEmpty ? "未安装" : installed.joined(separator: "、"))")
        if isRegistered() {
            log("✅ 系统已收录 InputFlow（可在 系统设置 → 键盘 → 文字输入 → 输入法 中添加）")
            progressTimer?.invalidate()
        } else {
            log("⏳ 系统暂未收录 InputFlow。若签名诊断显示 ad-hoc，这是预期结果；否则可注销重登后再试。")
        }
    }

    private func schedulePoll() {
        progressTimer?.invalidate()
        pollCount = 0
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pollCount += 1
            if self.isRegistered() {
                self.log("✅ 系统已收录 InputFlow")
                self.progressTimer?.invalidate()
            } else if self.pollCount >= 20 {
                self.log("⏳ 等待超时：系统未收录（ad-hoc 签名被拒属预期；有效签名请注销重登）")
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
        let purge = findPurgeCheck()?.state == .on

        runShell("/usr/bin/killall InputFlow")
        for path in [userAppPath, systemAppPath] where FileManager.default.fileExists(atPath: path) {
            if path.hasPrefix("/Library") {
                let script = "#!/bin/bash\nrm -rf \"\(path)\"\n"
                let tmp = NSTemporaryDirectory() + "inputflow-uninstall.sh"
                try? script.write(toFile: tmp, atomically: true, encoding: .utf8)
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
            let defaults = UserDefaults(suiteName: imeBundleID)
            defaults?.removePersistentDomain(forName: imeBundleID)
            runShell("/usr/bin/security delete-generic-password -s \(imeBundleID) -a userdata-key")
            try? FileManager.default.removeItem(atPath: userDataDir)
            log("已删除用户数据与钥匙串密钥")
        }
        checkRegistration()
    }

    private func findPurgeCheck() -> NSButton? {
        func search(_ view: NSView) -> NSButton? {
            if let check = view as? NSButton, check.identifier?.rawValue == "purge" {
                return check
            }
            for sub in view.subviews {
                if let found = search(sub) { return found }
            }
            return nil
        }
        return window?.contentView.flatMap(search)
    }

    // MARK: - 其他

    @objc private func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
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

@main
struct InstallerApp {
    static func main() {
        _ = NSApplication.shared
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let controller = InstallerWindowController()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        app.run()
    }
}
