import Foundation

/// 应用画像：按前台 App 自动选择标点风格与手势能力，无需用户配置。
///
/// - 代码/终端：保持半角标点（缩进、括号、引号都是语法）
/// - 浏览器：`aa` 进入网址模式（字母直通，Esc 退出）
/// - 聊天工具：`aa` 进入表情模式
/// - 其他：中文全角标点
struct AppProfile {
    var asciiPunctuation = false
    var urlGesture = false
    var memeGesture = false

    static let `default` = AppProfile()

    static func make(bundleId: String?) -> AppProfile {
        let id = bundleId ?? ""
        var profile = AppProfile()

        if matches(id, codeApps) {
            profile.asciiPunctuation = true
            return profile
        }
        if matches(id, chatApps) {
            profile.memeGesture = true
            return profile
        }
        if matches(id, browsers) {
            profile.urlGesture = true
            return profile
        }
        return profile
    }

    private static func matches(_ id: String, _ patterns: [String]) -> Bool {
        patterns.contains { pattern in
            if pattern.hasSuffix("*") {
                return id.hasPrefix(String(pattern.dropLast()))
            }
            return id == pattern
        }
    }

    /// 代码编辑器 / 终端 / IDE：标点保持半角。
    private static let codeApps: [String] = [
        "com.apple.dt.Xcode",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "com.sublimetext.*",
        "com.jetbrains.*",
        "com.google.android.studio",
        "dev.zed.Zed",
        "com.panic.Nova",
        "com.github.atom",
        "org.vim.MacVim",
        "com.qvacua.VimR",
        "com.apple.ScriptEditor2",
        "com.unity3d.*",
        "com.apple.iphonesimulator",
    ]

    /// 聊天工具：`aa` → 表情模式（斗图）。
    private static let chatApps: [String] = [
        "com.tencent.xinWeChat",
        "com.tencent.qq",
        "com.tencent.WeWorkMac",
        "com.alibaba.DingTalkMac",
        "com.bytedance.lark",
        "com.electron.lark",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "org.telegram.desktop",
        "ru.keepcoder.Telegram",
        "com.apple.MobileSMS",
        "com.apple.iChat",
        "com.microsoft.teams*",
        "com.facebook.archon",
    ]

    /// 浏览器：`aa` → 网址模式。
    private static let browsers: [String] = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome*",
        "com.microsoft.edgemac*",
        "org.mozilla.firefox*",
        "company.thebrowser.Browser",
        "com.brave.Browser*",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera*",
        "com.360.*",
        "com.tencent.*browser*",
        "ru.yandex.desktop.yandex-browser",
        "com.pushplaylabs.sidekick",
        "com.kagi.kagimacOS",
    ]
}
