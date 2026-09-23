import AppKit
import CryptoKit
import Foundation

/// 可下载的形象条目（VRM）。`sha256` 为空表示用户自加来源、下载后自动记录校验和。
struct PetCatalogEntry: Codable {
    var id: String
    var name: String
    var url: String
    var sha256: String?
    var bytes: Int64?
    var license: String
    var author: String?
    var homepage: String?
    var tags: [String]?
    var note: String?

    var sizeText: String {
        guard let bytes else { return "大小未知" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum PetModelCatalog {
    /// 官方 VRM Consortium 样例 Seed-san（VRM Public License 1.0；本项目不随包分发模型本体）
    static let seedSan = PetCatalogEntry(
        id: "pet-seed-san",
        name: "Seed-san（官方样例）",
        url: "https://raw.githubusercontent.com/vrm-c/vrm-specification/master/samples/Seed-san/vrm/Seed-san.vrm",
        sha256: "624d0d554bc205bbdc33e22a68a2c3c20edebb3e573011ead8878a65e5329b23",
        bytes: 10_917_800,
        license: "VRM Public License 1.0",
        author: "VRM Consortium",
        homepage: "https://github.com/vrm-c/vrm-specification",
        tags: ["official"],
        note: "VRM Consortium 官方样例形象"
    )
}

enum PetCatalogStore {
    struct Catalog: Codable {
        var entries: [PetCatalogEntry]
    }

    /// 用户目录：`~/Library/Application Support/InputFlow/pet-catalog.json`
    /// 可自由添加来源（名称 / URL / 许可），与内置目录按 id 合并。
    static var userCatalogURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InputFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("pet-catalog.json")
    }

    private static var bundledCatalogURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("PetCatalog.json")
    }

    static func entries() -> [PetCatalogEntry] {
        var merged: [String: PetCatalogEntry] = [:]
        for entry in load(from: bundledCatalogURL) {
            merged[entry.id] = entry
        }
        for entry in load(from: userCatalogURL) where !entry.id.isEmpty {
            // 用户目录优先，但保留内置校验和（若用户没写）
            var item = entry
            if (item.sha256 ?? "").isEmpty, let builtin = merged[entry.id], let hash = builtin.sha256 {
                item.sha256 = hash
            }
            merged[entry.id] = item
        }
        return merged.values.sorted { $0.name < $1.name }
    }

    static func addUserEntry(_ entry: PetCatalogEntry) throws {
        var catalog = load(from: userCatalogURL)
        catalog.removeAll { $0.id == entry.id }
        catalog.append(entry)
        try save(Catalog(entries: catalog), to: userCatalogURL)
    }

    static func removeUserEntry(id: String) throws {
        var catalog = load(from: userCatalogURL)
        catalog.removeAll { $0.id == id }
        try save(Catalog(entries: catalog), to: userCatalogURL)
    }

    /// 首次下载成功后记录校验和，后续下载都会校验。
    static func recordHash(id: String, sha256: String) {
        var catalog = load(from: userCatalogURL)
        if let index = catalog.firstIndex(where: { $0.id == id }) {
            catalog[index].sha256 = sha256
            try? save(Catalog(entries: catalog), to: userCatalogURL)
        }
    }

    static func jsonText(_ entries: [PetCatalogEntry]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Catalog(entries: entries)) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func load(from url: URL?) -> [PetCatalogEntry] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode(Catalog.self, from: data))?.entries ?? []
    }

    private static func save(_ catalog: Catalog, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(catalog).write(to: url)
    }
}

enum PetModelInstaller {
    /// 下载并安装为形象包；`sha256` 非空时必须校验通过，空则下载后记录校验和。
    static func install(
        _ entry: PetCatalogEntry,
        onProgress: @escaping (Double) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let url = URL(string: entry.url) else {
            completion(.failure(NSError(domain: "InputFlow.Pet", code: 1, userInfo: [NSLocalizedDescriptionKey: "模型地址无效"])))
            return
        }
        let destinationDir = PluginStore.pluginsDir.appendingPathComponent(entry.id, isDirectory: true)
        let task = URLSession.shared.downloadTask(with: url) { temp, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let temp else {
                completion(.failure(NSError(domain: "InputFlow.Pet", code: 2, userInfo: [NSLocalizedDescriptionKey: "下载失败"])))
                return
            }
            do {
                let digest = try sha256(of: temp)
                if let expected = entry.sha256, !expected.isEmpty, digest != expected.lowercased() {
                    try? FileManager.default.removeItem(at: temp)
                    throw NSError(domain: "InputFlow.Pet", code: 3, userInfo: [NSLocalizedDescriptionKey: "sha256 校验失败，已丢弃"])
                }
                let fm = FileManager.default
                try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
                let model = destinationDir.appendingPathComponent("model.vrm")
                try? fm.removeItem(at: model)
                try fm.moveItem(at: temp, to: model)
                try pluginJSON(entry).data(using: .utf8)?.write(to: destinationDir.appendingPathComponent("plugin.json"))
                try petJSON.data(using: .utf8)?.write(to: destinationDir.appendingPathComponent("pet.json"))
                PetCatalogStore.recordHash(id: entry.id, sha256: digest)
                onProgress(1.0)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
        onProgress(0.0)
        task.resume()
    }

    private static let petJSON = """
    {"renderer":"vrm","size":240,"width":240,"height":380,"framing":"full","zoom":1.0,
     "fps":30,"fps_idle":30,"fps_typing":60,"entry":"model.vrm",
     "follow_cursor":false,"typing_bounce":true,"commit_particles":true}
    """

    private static func pluginJSON(_ entry: PetCatalogEntry) -> String {
        let note = entry.note ?? "下载的形象"
        let author = entry.author ?? "未知作者"
        return """
        {"id":"\(entry.id)","name":"\(entry.name)","version":"1.0.0","kind":"pet",
         "authors":["\(author)"],"description":"\(note)","license":"\(entry.license)","permissions":[]}
        """
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
