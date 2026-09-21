import Foundation

/// 每应用中英模式记忆：内核统计模型（指数衰减投票）+ 本地持久化。
///
/// 学习信号只有两类——手动切换（Shift 裸按 / 菜单选择）与上屏行为，
/// 只存「应用 bundle id → 模式票数」，不存任何按键内容。
/// 关闭开关即清空全部学习结果，不留数据。
final class AppModeMemory {
    static let shared = AppModeMemory()

    private var handle: OpaquePointer?
    private let enabledKey = "InputFlowAppModeMemoryEnabled"
    private let blobKey = "InputFlowAppModeMemoryTSV"

    private init() {
        handle = inputflow_app_mode_new()
        if let h = handle {
            let blob = UserDefaults.standard.string(forKey: blobKey) ?? ""
            _ = blob.withCString { inputflow_app_mode_import(h, $0) }
        }
    }

    deinit {
        if let h = handle {
            inputflow_app_mode_free(h)
        }
    }

    /// 开关（默认开）。关闭时顺带清空学习结果。
    var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: enabledKey) == nil
                ? true
                : UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if !newValue {
                forgetAll()
            }
        }
    }

    /// 这个应用现在该用中文还是英文？nil = 样本不足，不干预。
    func preferredChinese(appId: String?) -> Bool? {
        guard isEnabled, let h = handle, let appId, !appId.isEmpty else { return nil }
        let verdict = appId.withCString {
            inputflow_app_mode_decide(h, $0, UInt64(Date().timeIntervalSince1970))
        }
        return verdict == 1 ? true : (verdict == 0 ? false : nil)
    }

    /// 记录一次信号。`strong` = 用户手动切换；否则是上屏弱信号。
    func observe(appId: String?, chinese: Bool, strong: Bool) {
        guard isEnabled, let h = handle, let appId, !appId.isEmpty else { return }
        _ = appId.withCString {
            inputflow_app_mode_observe(
                h, $0, chinese ? 1 : 0, strong ? 1 : 0,
                UInt64(Date().timeIntervalSince1970)
            )
        }
        flush()
    }

    /// 忘记单个应用的偏好。
    func forget(appId: String?) {
        guard let h = handle, let appId, !appId.isEmpty else { return }
        _ = appId.withCString { inputflow_app_mode_forget(h, $0) }
        flush()
    }

    /// 清空全部学习结果。
    func forgetAll() {
        if let h = handle {
            inputflow_app_mode_forget_all(h)
        }
        UserDefaults.standard.removeObject(forKey: blobKey)
    }

    private func flush() {
        guard let h = handle, let blob = takeString(inputflow_app_mode_export(h)) else { return }
        UserDefaults.standard.set(blob, forKey: blobKey)
    }

    private func takeString(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr else { return nil }
        defer { inputflow_free_string(ptr) }
        return String(cString: ptr)
    }
}
