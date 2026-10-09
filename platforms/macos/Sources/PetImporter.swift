import Foundation

/// 把用户导入 / 云端生成的 VRM 安装成桌宠形象包：
/// 写 `model.vrm` + `plugin.json` + `pet.json`，并返回形象包 id。
enum PetImporter {
    @discardableResult
    static func importVRM(
        from url: URL,
        packId: String = "vrm-custom",
        name: String = "自定义 VRM"
    ) throws -> String {
        let fm = FileManager.default
        let dest = PluginStore.pluginsDir.appendingPathComponent(packId, isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let model = dest.appendingPathComponent("model.vrm")
        try? fm.removeItem(at: model)
        try fm.copyItem(at: url, to: model)

        let description = "导入的 VRM 模型：\(url.lastPathComponent)"
        let plugin = """
        {"id":"\(packId)","name":"\(name)","version":"1.0.0","kind":"pet",\
        "authors":["user"],"description":"\(description)","license":"user-provided","permissions":[]}
        """
        let pet = """
        {"renderer":"vrm","size":220,"fps":30,"fps_idle":30,"fps_typing":60,\
        "entry":"model.vrm","follow_cursor":false,"typing_bounce":true,"commit_particles":true}
        """
        try plugin.data(using: .utf8)?.write(to: dest.appendingPathComponent("plugin.json"))
        try pet.data(using: .utf8)?.write(to: dest.appendingPathComponent("pet.json"))
        return packId
    }
}
