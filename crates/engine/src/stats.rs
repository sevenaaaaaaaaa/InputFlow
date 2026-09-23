//! 输入统计与每日总结：纯计算，零内容——只吃计数，吐指标。
//!
//! 隐私边界：这里永远不接触按键内容、上屏文本、应用名以外的东西；
//! 上层只传「今天删了几次、打了多少字」这类计数。卡路里是参考轻量桌面
//! 活动代谢率的粗略估算，图一乐，不做健康建议。

/// 活跃打字每分钟估算消耗（千卡）。轻量桌面活动的常见区间中取偏低值。
const KCAL_PER_ACTIVE_MIN: f64 = 0.9;
/// 发呆判定下限：两次事件间隔超过这个秒数，中间算「盯着光标发呆」。
pub const STARE_MIN_SECS: u64 = 5;
/// 单次发呆计入上限（防止挂机一晚上刷出天文数字）。
pub const STARE_CAP_SECS: u64 = 30 * 60;

/// 一天的计数（由平台前端累计并持久化）。
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct DayStats {
    /// 上屏字符数（不含语音）。
    pub chars: u64,
    /// 喂进引擎的按键数（字母区）。
    pub keys: u64,
    /// 删除键次数。
    pub deletes: u64,
    /// 回车键次数。
    pub enters: u64,
    /// 候选/整句节省的击键数（按键数 − 上屏字数，只计为正的部分）。
    pub saved_keys: u64,
    /// 语音上屏字符数。
    pub voice_chars: u64,
    /// 活跃打字秒数（相邻事件间隔 < 10s 的部分累计）。
    pub active_secs: u64,
    /// 当天最长一次发呆秒数。
    pub stare_max_secs: u64,
}

/// 总结指标。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Digest {
    /// 活跃打字速度：字/分钟。
    pub speed_cpm: f64,
    /// 手感准确率：1 − 删除/(上屏+删除)，百分数。
    pub accuracy: f64,
    /// 估算消耗（千卡）。
    pub kcal: f64,
    pub saved_keys: u64,
    pub voice_chars: u64,
    pub deletes: u64,
    pub enters: u64,
    /// 最长发呆秒数。
    pub stare_max_secs: u64,
}

impl Digest {
    pub fn compute(s: &DayStats) -> Self {
        let active_min = s.active_secs as f64 / 60.0;
        let speed_cpm = if active_min > 0.0 {
            s.chars as f64 / active_min
        } else {
            0.0
        };
        let total = s.chars + s.deletes;
        let accuracy = if total > 0 {
            (1.0 - s.deletes as f64 / total as f64) * 100.0
        } else {
            100.0
        };
        let kcal = active_min * KCAL_PER_ACTIVE_MIN;
        Self {
            speed_cpm,
            accuracy,
            kcal,
            saved_keys: s.saved_keys,
            voice_chars: s.voice_chars,
            deletes: s.deletes,
            enters: s.enters,
            stare_max_secs: s.stare_max_secs.min(STARE_CAP_SECS),
        }
    }

    /// 紧凑 JSON，供前端 toast / 卡片直接解码。
    pub fn to_json(&self) -> String {
        format!(
            "{{\"speed_cpm\":{:.1},\"accuracy\":{:.1},\"kcal\":{:.2},\"saved_keys\":{},\"voice_chars\":{},\"deletes\":{},\"enters\":{},\"stare_max_secs\":{}}}",
            self.speed_cpm,
            self.accuracy,
            self.kcal,
            self.saved_keys,
            self.voice_chars,
            self.deletes,
            self.enters,
            self.stare_max_secs,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_day_is_all_zero_and_never_divides_by_zero() {
        let d = Digest::compute(&DayStats::default());
        assert_eq!(d.speed_cpm, 0.0);
        assert_eq!(d.accuracy, 100.0);
        assert_eq!(d.kcal, 0.0);
        assert_eq!(d.stare_max_secs, 0);
    }

    #[test]
    fn speed_uses_active_time_only() {
        let s = DayStats {
            chars: 120,
            active_secs: 120,
            ..Default::default()
        };
        assert!((Digest::compute(&s).speed_cpm - 60.0).abs() < 1e-9);
    }

    #[test]
    fn accuracy_counts_deletes_against_chars() {
        let s = DayStats {
            chars: 90,
            deletes: 10,
            ..Default::default()
        };
        assert!((Digest::compute(&s).accuracy - 90.0).abs() < 1e-9);
    }

    #[test]
    fn kcal_scales_with_active_minutes() {
        let s = DayStats {
            active_secs: 600,
            ..Default::default()
        };
        assert!((Digest::compute(&s).kcal - 9.0).abs() < 1e-9);
    }

    #[test]
    fn stare_is_capped() {
        let s = DayStats {
            stare_max_secs: 100_000,
            ..Default::default()
        };
        assert_eq!(Digest::compute(&s).stare_max_secs, STARE_CAP_SECS);
    }

    #[test]
    fn json_roundtrip_shape() {
        let s = DayStats {
            chars: 100,
            keys: 300,
            deletes: 4,
            enters: 12,
            saved_keys: 88,
            voice_chars: 6,
            active_secs: 120,
            stare_max_secs: 42,
        };
        let json = Digest::compute(&s).to_json();
        assert!(json.contains("\"speed_cpm\":50.0"), "{json}");
        assert!(json.contains("\"accuracy\":96.2"), "{json}");
        assert!(json.contains("\"saved_keys\":88"), "{json}");
        assert!(json.contains("\"stare_max_secs\":42"), "{json}");
    }
}
