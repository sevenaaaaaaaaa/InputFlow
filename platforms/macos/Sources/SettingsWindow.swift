import AppKit

/// 兼容入口：旧菜单 / CLI `--ai-settings` 仍调用这个类，
/// 实际打开设置中心的「本地 AI」分区，避免两套界面各改各的。
final class AISettingsWindowController {
    static let shared = AISettingsWindowController()

    func show() {
        SettingsCenter.shared.show(section: .ai)
    }
}
