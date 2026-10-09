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

    /// 导入 Live2D 模型（文件夹或 .zip，内需含 `*.model3.json` 及贴图/.moc3/动作）。
    /// 整个模型目录会拷进形象包（保留相对结构），写 `plugin.json` + `pet.json`。
    /// 注意：Cubism Core（`live2dcubismcore.min.js`）仍需用户自备，见 ADR-0009。
    @discardableResult
    static func importLive2D(
        from url: URL,
        packId: String = "live2d-custom",
        name: String = "自定义 Live2D"
    ) throws -> String {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw NSError(domain: "Liana.Pet", code: 10, userInfo: [NSLocalizedDescriptionKey: "路径不存在"])
        }

        var tempDir: URL?
        defer { if let tempDir { try? fm.removeItem(at: tempDir) } }

        let sourceDir: URL
        if isDir.boolValue {
            sourceDir = url
        } else if url.pathExtension.lowercased() == "zip" {
            let tmp = fm.temporaryDirectory.appendingPathComponent("liana-live2d-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            tempDir = tmp
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-xk", url.path, tmp.path]
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw NSError(domain: "Liana.Pet", code: 11, userInfo: [NSLocalizedDescriptionKey: "解压失败"])
            }
            guard let container = modelContainer(in: tmp, fm: fm) else {
                throw NSError(domain: "Liana.Pet", code: 12, userInfo: [NSLocalizedDescriptionKey: "压缩包里没找到 *.model3.json"])
            }
            sourceDir = container
        } else {
            throw NSError(domain: "Liana.Pet", code: 13, userInfo: [NSLocalizedDescriptionKey: "请选择 Live2D 模型文件夹或 .zip"])
        }

        guard let model3 = findModel3(in: sourceDir, fm: fm) else {
            throw NSError(domain: "Liana.Pet", code: 14, userInfo: [NSLocalizedDescriptionKey: "没找到 *.model3.json"])
        }
        let entry = relativePath(model3, in: sourceDir)

        let dest = PluginStore.pluginsDir.appendingPathComponent(packId, isDirectory: true)
        try? fm.removeItem(at: dest)
        try fm.createDirectory(at: PluginStore.pluginsDir, withIntermediateDirectories: true)
        try fm.copyItem(at: sourceDir, to: dest)

        let description = "导入的 Live2D 模型：\(url.lastPathComponent)"
        let plugin = """
        {"id":"\(packId)","name":"\(name)","version":"1.0.0","kind":"pet",\
        "authors":["user"],"description":"\(description)","license":"user-provided","permissions":[]}
        """
        let pet = """
        {"renderer":"live2d","entry":"\(entry)","size":240,"width":240,"height":380,\
        "framing":"full","zoom":1.0,"scale":1.0,"fps":30,"fps_idle":30,"fps_typing":60,\
        "follow_cursor":true,"typing_bounce":true,"commit_particles":true}
        """
        try plugin.data(using: .utf8)?.write(to: dest.appendingPathComponent("plugin.json"))
        try pet.data(using: .utf8)?.write(to: dest.appendingPathComponent("pet.json"))
        return packId
    }

    // MARK: - Live2D 辅助

    /// 递归找第一个 `*.model3.json`。
    private static func findModel3(in dir: URL, fm: FileManager) -> URL? {
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in e where url.lastPathComponent.lowercased().hasSuffix(".model3.json") {
            return url
        }
        return nil
    }

    /// 解压后定位「含 model3.json 的目录」（即模型根）。
    private static func modelContainer(in root: URL, fm: FileManager) -> URL? {
        guard let model3 = findModel3(in: root, fm: fm) else { return nil }
        return model3.deletingLastPathComponent()
    }

    private static func relativePath(_ child: URL, in root: URL) -> String {
        let c = child.standardizedFileURL.path
        let r = root.standardizedFileURL.path
        if c.hasPrefix(r + "/") { return String(c.dropFirst(r.count + 1)) }
        return child.lastPathComponent
    }
}
