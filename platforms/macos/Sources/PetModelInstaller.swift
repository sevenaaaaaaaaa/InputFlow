import AppKit
import CryptoKit
import Foundation

/// 可一键下载的官方/开放授权 VRM 形象（用户点击才联网，下载后 sha256 校验）。
struct PetModelCatalogEntry {
    let id: String
    let name: String
    let url: String
    let sha256: String
    let bytes: Int64
    let license: String
    let note: String
}

enum PetModelCatalog {
    /// 官方 VRM Consortium 样例 Seed-san（VRM Public License 1.0，个人使用可用；本项目不随包分发）
    static let seedSan = PetModelCatalogEntry(
        id: "pet-seed-san",
        name: "Seed-san（官方样例）",
        url: "https://raw.githubusercontent.com/vrm-c/vrm-specification/master/samples/Seed-san/vrm/Seed-san.vrm",
        sha256: "624d0d554bc205bbdc33e22a68a2c3c20edebb3e573011ead8878a65e5329b23",
        bytes: 10_917_800,
        license: "VRM Public License 1.0",
        note: "VRM Consortium 官方样例形象；3D 注视/眨眼/物理自动生效"
    )
}

enum PetModelInstaller {
    /// 下载并安装为形象包；完成后切到该形象。
    static func install(_ entry: PetModelCatalogEntry, onProgress: @escaping (Double) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
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
                guard digest == entry.sha256.lowercased() else {
                    try? FileManager.default.removeItem(at: temp)
                    throw NSError(domain: "InputFlow.Pet", code: 3, userInfo: [NSLocalizedDescriptionKey: "sha256 校验失败，已丢弃"])
                }
                let fm = FileManager.default
                try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
                let model = destinationDir.appendingPathComponent("model.vrm")
                try? fm.removeItem(at: model)
                try fm.moveItem(at: temp, to: model)
                onProgress(1.0)
                try pluginJSON(entry).data(using: .utf8)?.write(to: destinationDir.appendingPathComponent("plugin.json"))
                try petJSON.data(using: .utf8)?.write(to: destinationDir.appendingPathComponent("pet.json"))
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

    private static func pluginJSON(_ entry: PetModelCatalogEntry) -> String {
        """
        {"id":"\(entry.id)","name":"\(entry.name)","version":"1.0.0","kind":"pet",
         "authors":["VRM Consortium"],"description":"\(entry.note)","license":"\(entry.license)","permissions":[]}
        """
    }

    private static func sha256(of url: URL) throws -> String {
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
