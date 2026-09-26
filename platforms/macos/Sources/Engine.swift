import Foundation

struct Candidate: Codable {
    let text: String
    let consumed: Int
    let kind: String
    let comment: String?
}

struct Composition: Codable {
    let mode: String
    let raw: String
    let preedit: String
    let candidates: [Candidate]

    static let empty = Composition(mode: "pinyin", raw: "", preedit: "", candidates: [])
}

/// 术语提炼结果（喂食层，纯统计）。
struct FeedTerm: Codable {
    let term: String
    let count: Int
}

/// 营养库条目。
struct NutritionItem: Codable {
    let term: String
    let keys: String
    let source: String
    let strength: Int
    let addedAt: UInt64
}

/// 内核 C ABI 的 Swift 封装。会话只在本进程内存中，不做任何网络访问。
final class InputFlowEngine {
    private var handle: OpaquePointer?

    /// 可选的外部词典：~/Library/Application Support/InputFlow/base.ifd
    private static let externalDict: String? = {
        let path = NSHomeDirectory() + "/Library/Application Support/InputFlow/base.ifd"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }()

    init(mode: String = "pinyin") {
        if let dict = Self.externalDict {
            handle = dict.withCString { path in mode.withCString { m in inputflow_new_with_dict(m, path) } }
        }
        if handle == nil {
            handle = mode.withCString { inputflow_new($0) }
        }
    }

    deinit {
        if let h = handle {
            inputflow_free(h)
        }
    }

    private func takeString(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr else { return nil }
        defer { inputflow_free_string(ptr) }
        return String(cString: ptr)
    }

    var composition: Composition {
        guard let h = handle,
              let json = takeString(inputflow_composition_json(h)),
              let data = json.data(using: .utf8),
              let comp = try? JSONDecoder().decode(Composition.self, from: data)
        else { return .empty }
        return comp
    }

    var hasComposition: Bool { !composition.raw.isEmpty }

    var mode: String { composition.mode }

    @discardableResult
    func feed(_ ch: Character) -> Bool {
        guard let h = handle else { return false }
        return String(ch).withCString { inputflow_feed(h, $0) == 1 }
    }

    @discardableResult
    func backspace() -> Bool {
        guard let h = handle else { return false }
        return inputflow_backspace(h) == 1
    }

    func clear() {
        if let h = handle { inputflow_clear(h) }
    }

    /// 候选是否以繁体呈现（学习与重排仍以简体为准）。
    var isTraditional: Bool {
        guard let h = handle else { return false }
        return inputflow_traditional(h) == 1
    }

    func setTraditional(_ on: Bool) {
        if let h = handle { _ = inputflow_set_traditional(h, on ? 1 : 0) }
    }

    func setMode(_ id: String) {
        if let h = handle { _ = id.withCString { inputflow_set_mode(h, $0) } }
    }

    func select(_ index: Int) -> String? {
        guard let h = handle else { return nil }
        return takeString(inputflow_select(h, UInt32(index)))
    }

    func commitRaw() -> String? {
        guard let h = handle else { return nil }
        return takeString(inputflow_commit_raw(h))
    }

    func exportUserModel() -> String {
        guard let h = handle, let s = takeString(inputflow_user_export(h)) else { return "" }
        return s
    }

    @discardableResult
    func importUserModel(_ tsv: String) -> Int {
        guard let h = handle else { return -1 }
        return Int(tsv.withCString { inputflow_user_import(h, $0) })
    }

    /// 外部上屏（语音识别结果）的学习：记词 + 二元组上下文，与打字共享一套学习。
    func recordCommit(_ text: String) {
        guard let h = handle, !text.isEmpty else { return }
        _ = text.withCString { inputflow_record_commit(h, $0) }
    }

    // MARK: - 知你教学层（ADR-0008 E1）：选词/删除序列 → 共享账本，排序接 adjust

    /// 会话激活时同步决策上下文与开关（app/hour/now 由前端供给）。
    func setEvolutionContext(app: String?, hour: UInt32, enabled: Bool) {
        guard let h = handle else { return }
        let now = UInt64(Date().timeIntervalSince1970)
        let cApp = app ?? ""
        _ = cApp.withCString { inputflow_set_evolution_context(h, $0, hour, enabled ? 1 : 0, now) }
    }

    /// 选词上屏后确认一次：数字键选了第 2+ 候选时 altRank = true。
    func noteEvolutionSelection(altRank: Bool) {
        guard let h = handle else { return }
        _ = inputflow_evolution_note_selection(h, altRank ? 1 : 0, UInt64(Date().timeIntervalSince1970))
    }

    /// 无组合态的删除键：交给内核判定是否「选了又删」。
    func noteEvolutionDelete() {
        guard let h = handle else { return }
        _ = inputflow_evolution_note_delete(h, UInt64(Date().timeIntervalSince1970))
    }

    func exportEvolution() -> String {
        guard let h = handle, let s = takeString(inputflow_evolution_session_export(h)) else { return "" }
        return s
    }

    @discardableResult
    func importEvolution(_ tsv: String) -> Int {
        guard let h = handle else { return -1 }
        return Int(tsv.withCString { inputflow_evolution_session_import(h, $0) })
    }

    func forgetEvolution() {
        if let h = handle { inputflow_evolution_session_forget(h) }
    }

    // MARK: - 知你喂食层（ADR-0008 E2）：术语提炼 + 营养库

    /// 术语提炼（纯函数，不经会话）：反复出现的 n-gram，次数降序。
    static func feedExtract(_ text: String) -> [FeedTerm] {
        guard !text.isEmpty,
              let json = text.withCString({ takeStatic(inputflow_feed_extract_json($0)) }),
              let data = json.data(using: .utf8),
              let terms = try? JSONDecoder().decode([FeedTerm].self, from: data)
        else { return [] }
        return terms
    }

    /// 喂入营养词；按键串由内核按词典读音派生。
    @discardableResult
    func nutritionAdd(term: String, source: String, strength: UInt32) -> Bool {
        guard let h = handle else { return false }
        return term.withCString { t in
            source.withCString { s in
                inputflow_nutrition_add(h, t, s, strength, UInt64(Date().timeIntervalSince1970)) == 1
            }
        }
    }

    func nutritionList() -> [NutritionItem] {
        guard let h = handle,
              let json = takeString(inputflow_nutrition_list_json(h)),
              let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([NutritionItem].self, from: data)
        else { return [] }
        return items
    }

    @discardableResult
    func nutritionForget(_ term: String) -> Bool {
        guard let h = handle else { return false }
        return term.withCString { inputflow_nutrition_forget(h, $0) == 1 }
    }

    func nutritionForgetAll() {
        if let h = handle { inputflow_nutrition_forget_all(h) }
    }

    func nutritionExport() -> String {
        guard let h = handle, let s = takeString(inputflow_nutrition_export(h)) else { return "" }
        return s
    }

    @discardableResult
    func nutritionImport(_ tsv: String) -> Int {
        guard let h = handle else { return -1 }
        return Int(tsv.withCString { inputflow_nutrition_import(h, $0) })
    }

    /// 导出备份包（明文 TSV + 版本头 + CRC32）；加密由 `BackupManager` 负责。
    func exportBackup() -> String {
        guard let h = handle, let s = takeString(inputflow_backup_export(h)) else { return "" }
        return s
    }

    /// 导入备份包，返回条目数；格式或校验失败返回 -1（不会改动现有数据）。
    @discardableResult
    func importBackup(_ text: String, merge: Bool) -> Int {
        guard let h = handle else { return -1 }
        return Int(text.withCString { inputflow_backup_import(h, $0, merge ? 1 : 0) })
    }

    // MARK: - 本地 AI 增强（目录与推荐；下载由 AIModelStore 负责）

    private static func takeStatic(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr else { return nil }
        defer { inputflow_free_string(ptr) }
        return String(cString: ptr)
    }

    static func aiCatalog() -> [AIModelInfo] {
        guard let json = takeStatic(inputflow_ai_catalog_json()),
              let data = json.data(using: .utf8),
              let models = try? JSONDecoder().decode([AIModelInfo].self, from: data)
        else { return [] }
        return models
    }

    static func aiRecommend(totalRamMb: Int) -> AIRecommendationSet {
        guard let json = takeStatic(inputflow_ai_recommend_json(UInt64(totalRamMb))),
              let data = json.data(using: .utf8),
              let set = try? JSONDecoder().decode(AIRecommendationSet.self, from: data)
        else {
            return AIRecommendationSet(totalRamMb: totalRamMb, recommendations: [])
        }
        return set
    }
}

/// 知你学习开关（默认开）。关闭即停止记账与重排；账本清空走「忘记」。
enum EvolutionLearning {
    static let enabledKey = "InputFlowEvolutionEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
    }
}

enum InputFlowMode: String, CaseIterable {
    case pinyin
    case flypy
    case mspy
    case zrm
    case en
    case ja

    var title: String {
        switch self {
        case .pinyin: return "拼音"
        case .flypy: return "小鹤双拼"
        case .mspy: return "微软双拼"
        case .zrm: return "自然码"
        case .en: return "English"
        case .ja: return "日本語"
        }
    }

    /// 中英切换时记住上一个中文模式。
    var isChinese: Bool { self != .en }

    /// 使用中文全角标点的模式（日语标点后续单独处理）。
    var usesChinesePunctuation: Bool {
        switch self {
        case .pinyin, .flypy, .mspy, .zrm: return true
        case .en, .ja: return false
        }
    }
}
