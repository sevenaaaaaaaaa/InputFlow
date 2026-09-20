import AppKit
import CommonCrypto
import CryptoKit
import Foundation

/// 备份与恢复：把用户词 / 二元组 / 短语导出成可搬运的文件，并能导回来。
///
/// 为什么不直接复制 `userdata.enc`：那个文件用本机钥匙串里的密钥加密，换台机器就打不开。
/// 备份包改用**用户设定的密码**派生密钥（PBKDF2-HMAC-SHA256 + ChaCha20-Poly1305），
/// 所以它能跨设备、跨系统恢复，而磁盘上的日常存储仍然只认本机密钥。
///
/// 备份内容只有输入学习数据，**不含剪切板历史**——那是另一类更敏感的东西，
/// 需要时用户可以在剪切板窗口里单独复制。
enum BackupManager {
    /// 加密包文件头：magic + 版本 + 盐。
    static let magic = Data("IFBK".utf8)
    static let version: UInt8 = 1
    static let saltBytes = 16
    /// PBKDF2 迭代次数。备份是一次性操作，慢一点换更高的离线爆破成本。
    static let iterations: UInt32 = 200_000

    enum Failure: LocalizedError {
        case notBackup
        case badPassword
        case random
        case rejected

        var errorDescription: String? {
            switch self {
            case .notBackup: return "这不是 InputFlow 备份文件"
            case .badPassword: return "密码不对，或文件已损坏"
            case .random: return "无法生成随机盐"
            case .rejected: return "备份内容校验失败，未改动任何数据"
            }
        }
    }

    // MARK: - 纯逻辑（可被 `--backup-smoke` 直接验证）

    static func derive(password: String, salt: Data) throws -> SymmetricKey {
        var derived = Data(count: 32)
        let status: Int32 = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltPtr in
                password.withCString { pw in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pw, strlen(pw),
                        saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        out.bindMemory(to: UInt8.self).baseAddress, 32
                    )
                }
            }
        }
        guard Int(status) == kCCSuccess else { throw Failure.badPassword }
        return SymmetricKey(data: derived)
    }

    static func seal(_ plaintext: String, password: String) throws -> Data {
        var salt = Data(count: saltBytes)
        let ok = salt.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, saltBytes, ptr.baseAddress!)
        }
        guard ok == errSecSuccess else { throw Failure.random }
        let header = magic + Data([version]) + salt
        let key = try derive(password: password, salt: salt)
        let box = try ChaChaPoly.seal(Data(plaintext.utf8), using: key, authenticating: header)
        return header + box.combined
    }

    static func open(_ data: Data, password: String) throws -> String {
        let headerLen = magic.count + 1 + saltBytes
        guard data.count > headerLen, data.prefix(magic.count) == magic else {
            throw Failure.notBackup
        }
        let salt = data.subdata(in: (magic.count + 1)..<headerLen)
        let header = data.prefix(headerLen)
        let key = try derive(password: password, salt: salt)
        guard
            let box = try? ChaChaPoly.SealedBox(combined: data.dropFirst(headerLen)),
            let plaintext = try? ChaChaPoly.open(box, using: key, authenticating: header),
            let text = String(data: plaintext, encoding: .utf8)
        else { throw Failure.badPassword }
        return text
    }

    /// 文件是否是加密包（否则按明文备份处理）。
    static func isEncrypted(_ data: Data) -> Bool {
        data.count > magic.count && data.prefix(magic.count) == magic
    }

    static func suggestedName(encrypted: Bool) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return "InputFlow-备份-\(f.string(from: Date()))." + (encrypted ? "ifbak" : "txt")
    }

    // MARK: - 导出

    static func exportEncrypted(engine: InputFlowEngine) {
        guard let password = askPassword() else { return }
        do {
            let data = try seal(engine.exportBackup(), password: password)
            save(data: data, name: suggestedName(encrypted: true))
        } catch {
            report(error)
        }
    }

    static func exportPlain(engine: InputFlowEngine) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "导出明文备份？"
        alert.informativeText =
            "明文备份里是你打过的词、搭配和短语，任何能读到这个文件的人都能看到。"
            + "日常备份建议选「导出加密备份」。"
        alert.addButton(withTitle: "仍然导出明文")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        save(data: Data(engine.exportBackup().utf8), name: suggestedName(encrypted: false))
    }

    private static func save(data: Data, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            report(error)
        }
    }

    // MARK: - 恢复

    static func restore(engine: InputFlowEngine, store: EncryptedStore) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择 InputFlow 备份文件（.ifbak 或明文 .txt）"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url)
        else { return }

        let text: String
        do {
            if isEncrypted(data) {
                guard let password = askPassword(confirm: false) else { return }
                text = try open(data, password: password)
            } else if let plain = String(data: data, encoding: .utf8) {
                text = plain
            } else {
                throw Failure.notBackup
            }
        } catch {
            report(error)
            return
        }

        let choice = NSAlert()
        choice.messageText = "如何恢复？"
        choice.informativeText =
            "「合并」保留本机现有的学习结果，同名条目取次数较大的一方；"
            + "「覆盖」用备份里的数据替换同名条目。两种方式都不会动剪切板历史。"
        choice.addButton(withTitle: "合并")
        choice.addButton(withTitle: "覆盖")
        choice.addButton(withTitle: "取消")
        let response = choice.runModal()
        guard response != .alertThirdButtonReturn else { return }
        let merge = response == .alertFirstButtonReturn

        let n = engine.importBackup(text, merge: merge)
        guard n >= 0 else {
            report(Failure.rejected)
            return
        }
        store.setUserModel(engine.exportUserModel())
        store.flush()

        let done = NSAlert()
        done.messageText = "已恢复 \(n) 条"
        done.informativeText = merge ? "已与本机现有数据合并。" : "已用备份覆盖同名条目。"
        done.runModal()
    }

    // MARK: - 辅助

    /// 密码输入框。`confirm` 为真时要求再输一次（导出场景，输错就永远打不开了）。
    static func askPassword(confirm: Bool = true) -> String? {
        let alert = NSAlert()
        alert.messageText = confirm ? "设置备份密码" : "输入备份密码"
        alert.informativeText = confirm
            ? "密码只用于加密这个文件，不会保存在任何地方——忘了就无法恢复。"
            : "输入导出这份备份时设置的密码。"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let first = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        first.placeholderString = "密码"
        let container: NSView
        var second: NSSecureTextField?
        if confirm {
            let again = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            again.placeholderString = "再输一次"
            second = again
            let stack = NSStackView(views: [first, again])
            stack.orientation = .vertical
            stack.spacing = 6
            stack.frame = NSRect(x: 0, y: 0, width: 240, height: 54)
            container = stack
        } else {
            container = first
        }
        alert.accessoryView = container
        alert.window.initialFirstResponder = first
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let password = first.stringValue
        if password.isEmpty {
            report(NSError(
                domain: "InputFlow.Backup", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "密码不能为空"]
            ))
            return nil
        }
        if let second, second.stringValue != password {
            report(NSError(
                domain: "InputFlow.Backup", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "两次输入的密码不一致"]
            ))
            return nil
        }
        return password
    }

    private static func report(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "备份操作未完成"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

// MARK: - 自检（`InputFlow --backup-smoke`）

extension BackupManager {
    /// 不弹任何窗口：验证「引擎导出 → 加密 → 解密 → 导回引擎」这条链路。
    static func smokeTest() -> Bool {
        var ok = true
        let source = InputFlowEngine(mode: "pinyin")
        _ = source.importUserModel("你好\t3\n@pair\t你好\t世界\t2\n@phrase\tnihaoshijie\t你好世界\t2\n")
        let packed = source.exportBackup()
        ok = ok && packed.hasPrefix("#IFBAK1")
        ok = ok && packed.contains("@phrase\tnihaoshijie\t你好世界\t2")

        guard let sealed = try? seal(packed, password: "correct horse") else {
            print("backup-smoke: 加密失败")
            return false
        }
        ok = ok && isEncrypted(sealed)
        ok = ok && sealed.range(of: Data("你好".utf8)) == nil
        ok = ok && (try? open(sealed, password: "correct horse")) == packed
        ok = ok && (try? open(sealed, password: "wrong")) == nil

        let target = InputFlowEngine(mode: "pinyin")
        ok = ok && target.importBackup(packed, merge: false) >= 2
        ok = ok && target.exportUserModel().contains("你好\t3")
        ok = ok && target.exportUserModel().contains("@phrase\tnihaoshijie\t你好世界\t2")

        // 合并幂等：再导一次计数不变
        _ = target.importBackup(packed, merge: true)
        ok = ok && target.exportUserModel().contains("你好\t3")
        // 损坏的包必须被拒绝
        ok = ok && target.importBackup(packed.replacingOccurrences(of: "你好\t3", with: "你好\t9"), merge: false) < 0
        ok = ok && target.importBackup("随便一段文本", merge: false) < 0

        print("backup-smoke: \(ok ? "通过" : "失败")")
        return ok
    }
}
