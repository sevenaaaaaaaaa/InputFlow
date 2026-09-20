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
