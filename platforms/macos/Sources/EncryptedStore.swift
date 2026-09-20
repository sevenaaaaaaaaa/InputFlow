import CryptoKit
import Foundation
import Security

/// 剪切板历史条目。
struct ClipboardItem: Codable, Equatable {
    let text: String
    let createdAt: Date
}

/// 加密持久化：`userdata.enc` = magic + 版本 + ChaChaPoly(JSON)。
///
/// 密钥优先来自钥匙串；不可用时本次运行退化为「仅内存」，绝不把密钥落盘。
/// 设计见 `docs/adr/0005-encrypted-persistence.md`。
final class EncryptedStore {
    static let shared = EncryptedStore()

    static let maxClipboardItems = 200
    static let maxClipboardItemBytes = 100 * 1024

    private(set) var clipboard: [ClipboardItem] = []
    private(set) var userModelTsv: String = ""
    /// 钥匙串是否可用（false = 本次运行不落盘）。
    private(set) var keyAvailable = false

    private let fileURL: URL
    private var key: SymmetricKey?
    private var saveWorkItem: DispatchWorkItem?
    private let service = "dev.inputflow.inputmethod"
    private let account = "userdata-key"

    private static let magic = Data("IFUE".utf8)
    private static let header = magic + Data([1])

    private struct Payload: Codable {
        var schemaVersion: Int
        var userModelTsv: String
        var clipboard: [ClipboardItem]
    }

    convenience init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InputFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.init(fileURL: base.appendingPathComponent("userdata.enc"))
    }

    init(fileURL: URL, key: SymmetricKey? = nil) {
        self.fileURL = fileURL
        if let key {
            self.key = key
            self.keyAvailable = true
        } else if let k = Self.keychainLoadOrCreate(service: service, account: account) {
            self.key = k
            self.keyAvailable = true
        } else {
            NSLog("InputFlow: 钥匙串不可用，本次运行的用户词/剪切板不会落盘")
        }
    }

    // MARK: - 加载 / 保存

    @discardableResult
    func load() -> Bool {
        guard let key else { return false }
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return false }
        do {
            let plaintext = try Self.open(data, key: key)
            let payload = try JSONDecoder().decode(Payload.self, from: plaintext)
            userModelTsv = payload.userModelTsv
            clipboard = payload.clipboard
            return true
        } catch {
            NSLog("InputFlow: userdata.enc 解析失败（\(error.localizedDescription)），按空数据处理")
            let backup = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            userModelTsv = ""
            clipboard = []
            return false
        }
    }

    func setUserModel(_ tsv: String) {
        userModelTsv = tsv
        markDirty()
    }

    /// 合并另一份用户词 TSV（多控制器同时使用时避免互相覆盖），按计数取大合并。
    func mergeUserModel(tsv: String) {
        guard !tsv.isEmpty else { return }
        var words: [String: Int] = [:]
        var pairs: [String: Int] = [:]
        parseTsv(userModelTsv, words: &words, pairs: &pairs)
        var incomingWords: [String: Int] = [:]
        var incomingPairs: [String: Int] = [:]
        parseTsv(tsv, words: &incomingWords, pairs: &incomingPairs)
        var changed = false
        for (w, c) in incomingWords where c > (words[w] ?? 0) {
            words[w] = c
            changed = true
        }
        for (p, c) in incomingPairs where c > (pairs[p] ?? 0) {
            pairs[p] = c
            changed = true
        }
        guard changed else { return }
        userModelTsv = Self.renderTsv(words: words, pairs: pairs)
        markDirty()
    }

    // MARK: - 剪切板

    /// 记录一条剪切板内容；返回是否有变化。超过上限/重复/过大时忽略。
    @discardableResult
    func recordClipboard(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, text.utf8.count <= Self.maxClipboardItemBytes else { return false }
        if clipboard.first?.text == text { return false }
        clipboard.removeAll { $0.text == text }
        clipboard.insert(ClipboardItem(text: text, createdAt: Date()), at: 0)
        if clipboard.count > Self.maxClipboardItems {
            clipboard.removeLast(clipboard.count - Self.maxClipboardItems)
        }
        markDirty()
        return true
    }

    func clearClipboard() {
        guard !clipboard.isEmpty else { return }
        clipboard = []
        markDirty()
    }

    func removeClipboard(_ item: ClipboardItem) {
        let before = clipboard.count
        clipboard.removeAll { $0 == item }
        if clipboard.count != before {
            markDirty()
        }
    }

    // MARK: - 落盘（防抖 + 原子写）

    func markDirty() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        guard let key, keyAvailable else { return }
        let payload = Payload(schemaVersion: 1, userModelTsv: userModelTsv, clipboard: clipboard)
        do {
            let plaintext = try JSONEncoder().encode(payload)
            let sealed = try Self.seal(plaintext, key: key)
            try sealed.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("InputFlow: 用户数据落盘失败（\(error.localizedDescription)）")
        }
    }

    // MARK: - 加密

    private static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, authenticating: header)
        return header + box.combined
    }

    private static func open(_ data: Data, key: SymmetricKey) throws -> Data {
        guard data.count > header.count, data.prefix(header.count) == header else {
            throw NSError(domain: "InputFlow.Store", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件头不匹配"])
        }
        let box = try ChaChaPoly.SealedBox(combined: data.dropFirst(header.count))
        return try ChaChaPoly.open(box, using: key, authenticating: header)
    }

    // MARK: - TSV 工具

    private func parseTsv(_ tsv: String, words: inout [String: Int], pairs: inout [String: Int]) {
        for line in tsv.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if fields.count == 4, fields[0] == "@pair", let c = Int(fields[3]) {
                pairs["\(fields[1])\t\(fields[2])"] = c
            } else if fields.count == 2, let c = Int(fields[1]) {
                words[String(fields[0])] = c
            }
        }
    }

    private static func renderTsv(words: [String: Int], pairs: [String: Int]) -> String {
        var out = ""
        for (w, c) in words.sorted(by: { $0.key < $1.key }) {
            out += "\(w)\t\(c)\n"
        }
        for (p, c) in pairs.sorted(by: { $0.key < $1.key }) {
            out += "@pair\t\(p)\t\(c)\n"
        }
        return out
    }

    // MARK: - 钥匙串

    private static func keychainLoadOrCreate(service: String, account: String) -> SymmetricKey? {
        if let existing = keychainLoad(service: service, account: account) {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        let data = Data(bytes)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return keychainLoad(service: service, account: account)
        }
        return status == errSecSuccess ? SymmetricKey(data: data) : nil
    }

    private static func keychainLoad(service: String, account: String) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }
}

// MARK: - 自检（`InputFlow --store-smoke`）

extension EncryptedStore {
    /// 加密存储往返自检：临时文件 + 随机密钥，不触碰真实钥匙串与用户文件。
    static func smokeTest() -> Bool {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inputflow-store-smoke-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("userdata.enc")
        let key = SymmetricKey(size: .bits256)
        var ok = true

        let a = EncryptedStore(fileURL: url, key: key)
        a.setUserModel("你好\t3\n@pair\t你好\t世界\t2\n")
        a.recordClipboard("第一段文本")
        a.recordClipboard("第一段文本") // 连续重复应忽略
        a.recordClipboard("第二段文本")
        a.flush()

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let perms = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let raw = try? Data(contentsOf: url)
        ok = ok && (perms & 0o777) == 0o600
        ok = ok && (raw?.count ?? 0) > 32
        ok = ok && !(raw?.range(of: Data("你好".utf8)) != nil)

        let b = EncryptedStore(fileURL: url, key: key)
        ok = ok && b.load()
        ok = ok && b.userModelTsv.contains("你好\t3")
        ok = ok && b.clipboard.count == 2
        ok = ok && b.clipboard.first?.text == "第二段文本"

        // 换错密钥必须读不出来
        let wrong = EncryptedStore(fileURL: url, key: SymmetricKey(size: .bits256))
        ok = ok && !wrong.load()

        // 合并：按计数取大，不覆盖对方独有的条目
        let merged = EncryptedStore(fileURL: dir.appendingPathComponent("merge.enc"), key: key)
        merged.setUserModel("你好\t3\n@pair\t你好\t世界\t2\n")
        merged.mergeUserModel(tsv: "你好\t1\n世界\t5\n@pair\t你好\t世界\t4\n@pair\t世界\t你好\t1\n")
        ok = ok && merged.userModelTsv.contains("你好\t3")
        ok = ok && merged.userModelTsv.contains("世界\t5")
        ok = ok && merged.userModelTsv.contains("@pair\t你好\t世界\t4")
        ok = ok && merged.userModelTsv.contains("@pair\t世界\t你好\t1")

        // 损坏文件应被隔离为 .corrupt
        try? Data("garbage".utf8).write(to: url)
        let c = EncryptedStore(fileURL: url, key: key)
        ok = ok && !c.load()
        ok = ok && FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path)

        print("store-smoke: \(ok ? "通过" : "失败")")
        print("钥匙串可用: \(EncryptedStore.shared.keyAvailable)")
        return ok
    }
}
