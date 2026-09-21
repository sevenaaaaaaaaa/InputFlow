import Foundation

/// 输入统计：只计数、不存内容。键数/删除/回车/上屏字数/节省击键/活跃秒数/最长发呆。
/// 数据存 UserDefaults（与按应用记忆同级的行为元数据），保留最近 7 天，可一键清空。
final class PetStats {
    static let shared = PetStats()

    struct Day: Codable {
        var chars = 0
        var keys = 0
        var deletes = 0
        var enters = 0
        var saved = 0
        var voice = 0
        var activeSecs = 0.0
        var stareMaxSecs = 0.0

        var isEmpty: Bool {
            chars == 0 && keys == 0 && deletes == 0 && enters == 0 && voice == 0
        }
    }

    private let storeKey = "InputFlowStatsDays"
    private let enabledKey = "InputFlowStatsEnabled"

    var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: enabledKey) == nil
                ? true
                : UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if !newValue {
                wipeAll()
            }
        }
    }

    private func days() -> [String: Day] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let dict = try? JSONDecoder().decode([String: Day].self, from: data)
        else { return [:] }
        return dict
    }

    private func save(_ days: [String: Day]) {
        // 只保留最近 7 天
        let cutoff = Self.dayKey(Date().addingTimeInterval(-7 * 86_400))
        let trimmed = days.filter { $0.key >= cutoff }
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    static func dayKey(_ date: Date = Date()) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }

    private func mutate(_ transform: (inout Day) -> Void) {
        guard isEnabled else { return }
        var days = days()
        let key = Self.dayKey()
        var day = days[key] ?? Day()
        transform(&day)
        days[key] = day
        save(days)
    }

    // MARK: - 记录（InputController 调）

    func recordKeys(_ n: Int) { mutate { $0.keys += n } }
    func recordDelete() { mutate { $0.deletes += 1 } }
    func recordEnter() { mutate { $0.enters += 1 } }
    /// 上屏：`keys` 是本次组合消耗的按键数，节省 = keys − 字数（为正才计）。
    func recordCommit(chars: Int, keys: Int) {
        mutate {
            $0.chars += chars
            $0.saved += max(0, keys - chars)
        }
    }
    /// 语音上屏（端上语音路径接通后计入）。
    func recordVoice(chars: Int) { mutate { $0.voice += chars } }
    /// 两次按键间隔 < 10s 计为活跃打字时间。
    func recordActive(seconds: Double) {
        mutate { $0.activeSecs += seconds }
    }
    /// 一次发呆结束（间隔 ≥ 5s），保留当天最长。
    func recordStare(seconds: Double) {
        mutate { $0.stareMaxSecs = max($0.stareMaxSecs, seconds) }
    }

    // MARK: - 读取

    func day(_ key: String) -> Day {
        days()[key] ?? Day()
    }

    var today: Day { day(Self.dayKey()) }

    var yesterday: Day { day(Self.dayKey(Date().addingTimeInterval(-86_400))) }

    func wipeAll() {
        UserDefaults.standard.removeObject(forKey: storeKey)
    }

    // MARK: - 指标（内核计算）

    struct Digest: Codable {
        let speed_cpm: Double
        let accuracy: Double
        let kcal: Double
        let saved_keys: Int
        let voice_chars: Int
        let deletes: Int
        let enters: Int
        let stare_max_secs: Int
    }

    /// 调内核把一天计数折算成指标（速度/准确率/卡路里等）。
    static func digest(_ day: Day) -> Digest? {
        let json = inputflow_stats_digest_json(
            UInt64(max(0, day.chars)), UInt64(max(0, day.keys)),
            UInt64(max(0, day.deletes)), UInt64(max(0, day.enters)),
            UInt64(max(0, day.saved)), UInt64(max(0, day.voice)),
            UInt64(max(0, Int(day.activeSecs))), UInt64(max(0, Int(day.stareMaxSecs)))
        )
        guard let json else { return nil }
        defer { inputflow_free_string(json) }
        guard
            let data = String(cString: json).data(using: .utf8),
            let digest = try? JSONDecoder().decode(Digest.self, from: data)
        else { return nil }
        return digest
    }

    /// 总结文案（多行，用于桌宠气泡卡片）。
    static func summaryText(for day: Day, title: String) -> String? {
        guard let d = digest(day) else { return nil }
        func dur(_ secs: Int) -> String {
            secs >= 60 ? "\(secs / 60) 分 \(secs % 60) 秒" : "\(secs) 秒"
        }
        var lines = ["📊 \(title)"]
        if day.isEmpty {
            lines.append("还没有输入记录，明天来看看吧")
            return lines.joined(separator: "\n")
        }
        lines.append("速度 \(Int(d.speed_cpm.rounded())) 字/分 · 准确率 \(Int(d.accuracy.rounded()))%")
        var third = "纠错 \(d.deletes) 次 · 回车 \(d.enters) 次"
        if d.saved_keys > 0 {
            third += " · 省了 \(d.saved_keys) 次击键"
        }
        lines.append(third)
        var fourth = "最长发呆 \(dur(d.stare_max_secs)) · ≈\(String(format: "%.1f", d.kcal)) 千卡"
        if d.voice_chars > 0 {
            fourth += " · 语音 \(d.voice_chars) 字"
        }
        lines.append(fourth)
        return lines.joined(separator: "\n")
    }
}
