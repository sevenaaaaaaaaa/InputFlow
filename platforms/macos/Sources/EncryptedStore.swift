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
    /// 知你账本 TSV（词\t特征\t亲和度\t观察数\t最后触摸），随 userdata.enc 加密落盘。
    private(set) var evolutionTsv: String = ""
    /// 营养库 TSV（词\t按键串\t出处\t强度\t加入时间），喂食层的落盘。
    private(set) var nutritionTsv: String = ""
    /// 钥匙串是否可用（false = 本次运行不落盘）。
    private(set) var keyAvailable = false

    private let fileURL: URL
    private var key: SymmetricKey?
    private var saveWorkItem: DispatchWorkItem?
    private let service = Bundle.main.bundleIdentifier ?? "dev.inputflow.inputmethod"
    private let account = "userdata-key"

    private static let magic = Data("IFUE".utf8)
    private static let header = magic + Data([1])

    private struct Payload: Codable {
        var schemaVersion: Int
        var userModelTsv: String
        /// v2 起新增；解码 v1 旧档时为 nil。
        var evolutionTsv: String?
        /// v3 起新增（喂食层营养库）；解码 v1/v2 旧档时为 nil。
        var nutritionTsv: String?
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
            evolutionTsv = payload.evolutionTsv ?? ""
            nutritionTsv = payload.nutritionTsv ?? ""
            clipboard = payload.clipboard
            return true
        } catch {
            NSLog("InputFlow: userdata.enc 解析失败（\(error.localizedDescription)），按空数据处理")
            let backup = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            userModelTsv = ""
            evolutionTsv = ""
            nutritionTsv = ""
            clipboard = []
            return false
        }
    }

    func setUserModel(_ tsv: String) {
        userModelTsv = tsv
        markDirty()
    }

    /// 覆盖知你账本（权限中心「一键忘记」后归零走这里）。
    func setEvolution(_ tsv: String) {
        evolutionTsv = tsv
        markDirty()
    }

    /// 合并另一份知你账本 TSV（多控制器同时使用时避免互相覆盖）：
    /// 同一 (词, 特征) 取「最后触摸」较新的整行——亲和度与观察数是一体的。
    func mergeEvolution(tsv: String) {
        guard !tsv.isEmpty else { return }
        var rows: [String: [String]] = [:]
        _ = Self.mergeDatedRows(evolutionTsv, into: &rows) {
            Float($0[2]) != nil && Int($0[3]) != nil
        }
        guard Self.mergeDatedRows(tsv, into: &rows, validate: { Float($0[2]) != nil && Int($0[3]) != nil })
        else { return }
        evolutionTsv = Self.renderDatedRows(rows)
        markDirty()
    }

    /// 覆盖营养库（权限中心「清空」后归零走这里）。
    func setNutrition(_ tsv: String) {
        nutritionTsv = tsv
        markDirty()
    }

    /// 合并另一份营养库 TSV：同一词取「加入时间」较新的整行。
    func mergeNutrition(tsv: String) {
        guard !tsv.isEmpty else { return }
        var rows: [String: [String]] = [:]
        _ = Self.mergeDatedRows(nutritionTsv, into: &rows) { Int($0[3]) != nil }
        guard Self.mergeDatedRows(tsv, into: &rows, validate: { Int($0[3]) != nil }) else { return }
        nutritionTsv = Self.renderDatedRows(rows)
        markDirty()
    }

    /// 合并另一份用户词 TSV（多控制器同时使用时避免互相覆盖），按计数取大合并。
    ///
    /// 行类型无关：词（`词\t次数`）、二元组（`@pair\t…`）、短语（`@phrase\t…`）
    /// 一律按「除最后一列以外的全部字段」当键，所以内核以后加新行类型也不会在这里丢数据。
    func mergeUserModel(tsv: String) {
        guard !tsv.isEmpty else { return }
        var records: [String: Int] = [:]
        Self.parseTsv(userModelTsv, into: &records)
        var incoming: [String: Int] = [:]
        Self.parseTsv(tsv, into: &incoming)
        var changed = false
        for (key, c) in incoming where c > (records[key] ?? 0) {
            records[key] = c
            changed = true
        }
        guard changed else { return }
        userModelTsv = Self.renderTsv(records)
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
        let payload = Payload(
            schemaVersion: 3,
            userModelTsv: userModelTsv,
            evolutionTsv: evolutionTsv,
            nutritionTsv: nutritionTsv,
            clipboard: clipboard
        )
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

    /// 键 = 除次数外的全部字段（用制表符连接），值 = 次数。
    private static func parseTsv(_ tsv: String, into records: inout [String: Int]) {
        for line in tsv.split(separator: "\n") {
            var fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2, let c = Int(fields.removeLast()) else { continue }
            let key = fields.joined(separator: "\t")
            guard !key.isEmpty else { continue }
            records[key] = c
        }
    }

    private static func renderTsv(_ records: [String: Int]) -> String {
        var out = ""
        for (key, c) in records.sorted(by: { $0.key < $1.key }) {
            out += "\(key)\t\(c)\n"
        }
        return out
    }

    /// 五列带时间戳的行（知你账本 / 营养库共用）：末列是 Unix 秒，
    /// 键 = 前两列；已有同键行时间不早于新行时不覆盖。有实际变化时返回 true。
    private static func mergeDatedRows(
        _ tsv: String,
        into rows: inout [String: [String]],
        validate: ([String]) -> Bool
    ) -> Bool {
        var changed = false
        for line in tsv.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, !fields[0].isEmpty, !fields[1].isEmpty,
                  validate(fields), let last = UInt64(fields[4])
            else { continue }
            let key = "\(fields[0])\t\(fields[1])"
            if let existing = rows[key], let prevLast = UInt64(existing[4]), prevLast >= last {
                continue
            }
            rows[key] = fields
            changed = true
        }
        return changed
    }

    private static func renderDatedRows(_ rows: [String: [String]]) -> String {
        var out = ""
        for (_, fields) in rows.sorted(by: { $0.key < $1.key }) {
            out += fields.joined(separator: "\t") + "\n"
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
        a.setEvolution("你好\tapp:com.apple.Notes\t0.5250\t2\t1000\n")
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
        ok = ok && b.evolutionTsv.contains("你好\tapp:com.apple.Notes\t0.5250\t2\t1000")
        ok = ok && b.clipboard.count == 2
        ok = ok && b.clipboard.first?.text == "第二段文本"

        // 换错密钥必须读不出来
        let wrong = EncryptedStore(fileURL: url, key: SymmetricKey(size: .bits256))
        ok = ok && !wrong.load()

        // 合并：按计数取大，不覆盖对方独有的条目
        let merged = EncryptedStore(fileURL: dir.appendingPathComponent("merge.enc"), key: key)
        merged.setUserModel("你好\t3\n@pair\t你好\t世界\t2\n")
        merged.mergeUserModel(
            tsv: "你好\t1\n世界\t5\n@pair\t你好\t世界\t4\n@pair\t世界\t你好\t1\n"
                + "@phrase\tnihaoshijie\t你好世界\t3\n")
        ok = ok && merged.userModelTsv.contains("你好\t3")
        ok = ok && merged.userModelTsv.contains("世界\t5")
        ok = ok && merged.userModelTsv.contains("@pair\t你好\t世界\t4")
        ok = ok && merged.userModelTsv.contains("@pair\t世界\t你好\t1")
        ok = ok && merged.userModelTsv.contains("@phrase\tnihaoshijie\t你好世界\t3")

        // 知你账本合并：同键取「最后触摸」较新的整行，坏行跳过
        merged.mergeEvolution(tsv: "你好\tapp:old\t0.1000\t1\t500\n你好\tapp:new\t0.3500\t2\t2000\n坏行\n")
        ok = ok && merged.evolutionTsv.contains("你好\tapp:old\t0.1000\t1\t500")
        merged.mergeEvolution(tsv: "你好\tapp:old\t0.9000\t3\t800\n")
        ok = ok && merged.evolutionTsv.contains("你好\tapp:old\t0.1000\t1\t500")
        ok = ok && merged.evolutionTsv.contains("你好\tapp:new\t0.3500\t2\t2000")

        // 营养库合并：同词取「加入时间」较新的整行
        merged.setNutrition("")
        merged.mergeNutrition(tsv: "张江高科\tzhangjianggaoke\t旧文档\t2\t500\n")
        merged.mergeNutrition(tsv: "张江高科\tzhangjianggaoke\t新文档\t5\t2000\n坏行\n缺\t列\t1\n")
        ok = ok && merged.nutritionTsv.contains("张江高科\tzhangjianggaoke\t新文档\t5\t2000")
        ok = ok && !merged.nutritionTsv.contains("旧文档")
        merged.mergeNutrition(tsv: "张江高科\tzhangjianggaoke\t更老\t1\t100\n")
        ok = ok && merged.nutritionTsv.contains("新文档\t5\t2000")

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
