import AppKit
import Carbon
import InputMethodKit

// MARK: - 安装辅助命令（注册 / 启用 / 选择 / 状态）
// 与 Squirrel 相同的做法：由输入法自身调用 TIS API，安装后无需注销即可被系统发现。

private func inputSourceID() -> String {
    Bundle.main.bundleIdentifier ?? "dev.inputflow.inputmethod"
}

private func findInputSources() -> [TISInputSource] {
    guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
        return []
    }
    let prefix = inputSourceID()
    return list.filter { source in
        let idRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        guard let id = unsafeBitCast(idRef, to: CFString?.self) as String? else { return false }
        return id.hasPrefix(prefix)
    }
}

private func findInputSource() -> TISInputSource? {
    let sources = findInputSources()
    return sources.first { boolProperty($0, kTISPropertyInputSourceIsSelectCapable) == true }
        ?? sources.first
}

private func sourceIdentifier(_ source: TISInputSource) -> String {
    let idRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
    return (unsafeBitCast(idRef, to: CFString?.self) as String?) ?? inputSourceID()
}

private func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool? {
    guard let ref = TISGetInputSourceProperty(source, key) else { return nil }
    return unsafeBitCast(ref, to: CFBoolean?.self).map(CFBooleanGetValue)
}

private func describe(_ source: TISInputSource) -> String {
    let enabled = boolProperty(source, kTISPropertyInputSourceIsEnabled) ?? false
    let selectable = boolProperty(source, kTISPropertyInputSourceIsSelectCapable) ?? false
    let selected = boolProperty(source, kTISPropertyInputSourceIsSelected) ?? false
    return "\(sourceIdentifier(source)) enabled=\(enabled) selectable=\(selectable) selected=\(selected)"
}

let installArgs = CommandLine.arguments
if installArgs.count > 1 {
    switch installArgs[1] {
    case "--register-input-source":
        if let source = findInputSource() {
            print("已注册: \(inputSourceID()) (\(describe(source)))")
            exit(0)
        }
        let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
        if status == noErr, let source = findInputSource() {
            print("注册成功: \(inputSourceID()) (\(describe(source)))")
            exit(0)
        }
        print("注册失败 (status=\(status))")
        exit(1)

    case "--enable-input-source":
        let sources = findInputSources()
        guard !sources.isEmpty else {
            print("未找到输入源，请先 --register-input-source")
            exit(1)
        }
        // 输入法容器与其模式需要一起启用，否则菜单栏不会出现
        var allOK = true
        for source in sources {
            if boolProperty(source, kTISPropertyInputSourceIsEnabled) == true {
                print("已启用: \(describe(source))")
                continue
            }
            let status = TISEnableInputSource(source)
            if status == noErr {
                print("启用成功: \(describe(source))")
            } else {
                print("启用失败 (status=\(status)): \(sourceIdentifier(source))")
                allOK = false
            }
        }
        exit(allOK ? 0 : 1)

    case "--select-input-source":
        guard let source = findInputSource(), boolProperty(source, kTISPropertyInputSourceIsEnabled) == true else {
            print("输入源未启用，请先 --enable-input-source")
            exit(1)
        }
        if boolProperty(source, kTISPropertyInputSourceIsSelected) == true {
            print("已选中")
            exit(0)
        }
        let status = TISSelectInputSource(source)
        print(status == noErr ? "已切换到 InputFlow" : "切换失败 (status=\(status))")
        exit(status == noErr ? 0 : 1)

    case "--input-source-status":
        guard let source = findInputSource() else {
            print("未注册")
            exit(1)
        }
        print("\(inputSourceID()) \(describe(source))")
        exit(0)

    case "--ai-dump":
        for model in InputFlowEngine.aiCatalog() {
            print(
                "\(model.id)\t\(model.sizeBytes)\t\(model.ramMb)MB\t\(model.kinds.joined(separator: ","))\t\(model.license)"
            )
        }
        let ramMb = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        let rec = InputFlowEngine.aiRecommend(totalRamMb: ramMb)
        print("totalRamMb=\(rec.totalRamMb)")
        for r in rec.recommendations {
            print("\(r.kind)\t\(r.modelId ?? "-")\t\(r.levelLabel)")
        }
        exit(0)

    case "--backup-smoke":
        exit(BackupManager.smokeTest() ? 0 : 1)

    case "--store-smoke":
        exit(EncryptedStore.smokeTest() ? 0 : 1)

    case "--candidate-demo":
        let demoEngine = InputFlowEngine(mode: "pinyin")
        for ch in "nihao" { _ = demoEngine.feed(ch) }
        let comp = demoEngine.composition
        let demoWindow = CandidateWindowController()
        demoWindow.present(
            candidates: comp.candidates,
            page: 0,
            near: NSRect(x: 300, y: 300, width: 2, height: 18),
            onPick: { _ in }
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let out = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/candidate-demo.png"
        demoWindow.snapshot(to: out)
        print("候选数=\(comp.candidates.count)，已渲染: \(out)")
        exit(0)

    case "--clipboard-smoke":
        ClipboardMonitor.shared.setEnabled(true)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("clipboard-test-\(UUID().uuidString)", forType: .string)
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        EncryptedStore.shared.flush()
        print("clipboardItems=\(EncryptedStore.shared.clipboard.count)")
        exit(EncryptedStore.shared.clipboard.isEmpty ? 1 : 0)

    case "--store-info":
        _ = EncryptedStore.shared.load()
        print("bundleId=\(Bundle.main.bundleIdentifier ?? "nil")")
        print("clipboardEnabled=\(UserDefaults.standard.bool(forKey: ClipboardMonitor.enabledKey))")
        print("keyAvailable=\(EncryptedStore.shared.keyAvailable)")
        print("userModelTsvBytes=\(EncryptedStore.shared.userModelTsv.utf8.count)")
        print("clipboardItems=\(EncryptedStore.shared.clipboard.count)")
        exit(0)

    case "--ai-settings":
        AISettingsWindowController.shared.show()
        NSApplication.shared.run()
        exit(0)

    case "--pet-switch-test":
        // 进程内连续切换形象包并快照，验证切换是否真的生效
        PluginStore.seedBundledPacks()
        PetWindowController.setEnabled(true)
        let dir = installArgs.count > 2 ? installArgs[2] : "/tmp/pet-switch"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for id in ["pet-orange-cat", "pet-robot", "pet-oriental-beauty", "pet-orange-cat"] {
            PetWindowController.activePackId = id
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let path = "\(dir)/\(id).png"
            PetWindowController.shared.snapshot(to: path)
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            print("switch -> \(id)  snapshot=\(size ?? 0)B")
        }
        exit(0)

    case "--pet-demo":
        PluginStore.seedBundledPacks()
        let packId = installArgs.count > 2 ? installArgs[2] : ""
        PetWindowController.activePackId = packId
        PetWindowController.setEnabled(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        let out = installArgs.count > 3 ? installArgs[3] : "/tmp/pet-demo.png"
        PetWindowController.shared.snapshot(to: out)
        print("pack=\(packId.isEmpty ? "builtin" : packId) -> \(out)")
        exit(0)

    case "--pets":
        PluginStore.seedBundledPacks()
        let catalog = PluginStore.scan()
        print("插件包共 \(catalog.packs.count) 个：")
        for pack in catalog.packs {
            print("  [\(pack.kind)] \(pack.id)\t\(pack.name)\t\(pack.description ?? "")")
        }
        for error in catalog.errors {
            print("  ! \(error.dir): \(error.error)")
        }
        exit(0)

    case "--clipboard-window":
        ClipboardWindowController.shared.show()
        NSApplication.shared.run()
        exit(0)

    case "--pet-window":
        PetWindowController.setEnabled(true)
        PetWindowController.shared.react(.commit)
        NSApplication.shared.run()
        exit(0)

    default:
        break
    }
}

// MARK: - 输入法主进程

// M1：加密用户数据（钥匙串密钥；不可用则本次仅内存）+ 剪切板监控（默认关闭）
_ = NSApplication.shared
PluginStore.seedBundledPacks()
_ = EncryptedStore.shared.load()
ClipboardMonitor.shared.startIfEnabled()
PetWindowController.restoreIfEnabled()
NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification,
    object: nil,
    queue: .main
) { _ in
    EncryptedStore.shared.flush()
}

let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String
    ?? "InputFlow_Connection"

guard let server = IMKServer(name: connectionName, bundleIdentifier: inputSourceID()) else {
    NSLog("InputFlow: 创建 IMKServer 失败（检查 Info.plist 的 InputMethodConnectionName）")
    exit(1)
}

// 保留 server 到进程结束
_ = server
NSApplication.shared.run()
