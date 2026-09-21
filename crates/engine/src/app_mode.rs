//! 每应用中英模式记忆：本地统计模型（指数衰减投票 + 置信度判定）。
//!
//! 只回答一个问题：「切到这个应用时，该用中文还是英文？」
//! 隐私边界：只存「应用 bundle id → 模式票数」，不存按键内容、不存时间线明细。
//!
//! 信号有两类：
//! - 手动切换（Shift 裸按 / 菜单选择）是强意图，一票即足以确立偏好；
//! - 上屏是弱信号（这个应用里在用哪种语言写字），按天封顶，防止长文淹没手动切换。
//!
//! 旧票按半衰期淡忘：换工作流半年后，旧习惯不会一直纠缠。

use std::collections::BTreeMap;

/// 手动切换的票重：明确意图，一票即足以确立（并压过弱信号）。
const TOGGLE_WEIGHT: f32 = 3.0;
/// 单次上屏的弱票重。
const COMMIT_WEIGHT: f32 = 0.2;
/// 上屏票按天封顶：一个自然日内最多贡献这么多票。
const DAILY_COMMIT_CAP: f32 = 1.0;
/// 票的半衰期：14 天。
const HALF_LIFE_SECS: f64 = 14.0 * 24.0 * 3600.0;
/// 判定「记得住」的门槛：胜方至少这么多分，且对败方有这么大的优势比。
const CONFIDENT_MIN: f32 = 2.0;
const CONFIDENT_RATIO: f32 = 2.0;
/// 记录的应用数上限：超出时挤掉最久没更新的（防御异常超长的应用列表）。
const MAX_ENTRIES: usize = 256;

#[derive(Debug, Clone, Default, PartialEq)]
struct Entry {
    zh: f32,
    en: f32,
    /// 上屏票的按天计数器（Unix 天），跨天清零。
    commit_day: u64,
    commit_votes: f32,
    updated_at: u64,
}

/// 应用 → 中英偏好的本地学习器。纯逻辑、零依赖，持久化由前端负责。
#[derive(Debug, Default)]
pub struct AppModeMemory {
    entries: BTreeMap<String, Entry>,
}

/// bundle id 只做最小净化：去首尾空白；为空或含制表/换行/控制字符则拒绝。
fn sanitize(app: &str) -> Option<String> {
    let trimmed = app.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed
        .chars()
        .any(|c| c == '\t' || c == '\n' || c == '\r' || c.is_control())
    {
        return None;
    }
    Some(trimmed.to_string())
}

fn decay(score: f32, from: u64, now: u64) -> f32 {
    if now <= from {
        return score;
    }
    let dt = (now - from) as f64;
    ((score as f64) * 0.5f64.powf(dt / HALF_LIFE_SECS)) as f32
}

impl Entry {
    /// 把旧票折算到 `now`（半衰期衰减），之后才能累加新票。
    fn fold_decay(&mut self, now: u64) {
        self.zh = decay(self.zh, self.updated_at, now);
        self.en = decay(self.en, self.updated_at, now);
        self.updated_at = now;
    }
}

impl AppModeMemory {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// 记录一次信号。`strong` = 用户手动切换；否则是上屏弱信号。
    /// 返回是否被记录（应用 id 非法时忽略）。
    pub fn observe(&mut self, app: &str, chinese: bool, strong: bool, now: u64) -> bool {
        let Some(key) = sanitize(app) else {
            return false;
        };
        {
            let entry = self.entries.entry(key.clone()).or_default();
            let weight = if strong {
                entry.fold_decay(now);
                TOGGLE_WEIGHT
            } else {
                let day = now / 86_400;
                if entry.commit_day != day {
                    entry.commit_day = day;
                    entry.commit_votes = 0.0;
                }
                let budget = (DAILY_COMMIT_CAP - entry.commit_votes).max(0.0);
                let w = COMMIT_WEIGHT.min(budget);
                entry.commit_votes += w;
                w
            };
            if chinese {
                entry.zh += weight;
            } else {
                entry.en += weight;
            }
            entry.updated_at = now;
        }
        if self.entries.len() > MAX_ENTRIES {
            let oldest = self
                .entries
                .iter()
                .filter(|(k, _)| k.as_str() != key)
                .min_by_key(|(_, e)| e.updated_at)
                .map(|(k, _)| k.clone());
            if let Some(oldest) = oldest {
                self.entries.remove(&oldest);
            }
        }
        true
    }

    /// 这个应用现在该用中文还是英文？样本不足或意见分裂时返回 None（不干预）。
    pub fn decide(&self, app: &str, now: u64) -> Option<bool> {
        let key = sanitize(app)?;
        let entry = self.entries.get(&key)?;
        let zh = decay(entry.zh, entry.updated_at, now);
        let en = decay(entry.en, entry.updated_at, now);
        let (win, lose) = if zh >= en { (zh, en) } else { (en, zh) };
        if win < CONFIDENT_MIN {
            return None;
        }
        if lose <= 0.0 {
            return Some(zh >= en);
        }
        if win / lose >= CONFIDENT_RATIO {
            return Some(zh >= en);
        }
        None
    }

    /// 忘记单个应用的偏好。返回是否存在过。
    pub fn forget(&mut self, app: &str) -> bool {
        let Some(key) = sanitize(app) else {
            return false;
        };
        self.entries.remove(&key).is_some()
    }

    /// 清空全部学习结果（关闭学习开关时顺带调用，不留数据）。
    pub fn forget_all(&mut self) {
        self.entries.clear();
    }


    /// 导出为 TSV（应用\t中文票\t英文票\t上屏天\t上屏票\t更新时间）。
    pub fn export_tsv(&self) -> String {
        let mut out = String::new();
        for (app, e) in &self.entries {
            out.push_str(app);
            out.push('\t');
            out.push_str(&format!("{:.3}", e.zh));
            out.push('\t');
            out.push_str(&format!("{:.3}", e.en));
            out.push('\t');
            out.push_str(&e.commit_day.to_string());
            out.push('\t');
            out.push_str(&format!("{:.3}", e.commit_votes));
            out.push('\t');
            out.push_str(&e.updated_at.to_string());
            out.push('\n');
        }
        out
    }

    /// 导入 TSV，返回成功导入的行数；坏行跳过，绝不 panic。
    pub fn import_tsv(&mut self, tsv: &str) -> usize {
        let mut imported = 0;
        for line in tsv.lines() {
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() != 6 {
                continue;
            }
            let (Some(zh), Some(en)) = (f[1].parse::<f32>().ok(), f[2].parse::<f32>().ok()) else {
                continue;
            };
            let (Some(day), Some(votes), Some(at)) = (
                f[3].parse::<u64>().ok(),
                f[4].parse::<f32>().ok(),
                f[5].parse::<u64>().ok(),
            ) else {
                continue;
            };
            let Some(key) = sanitize(f[0]) else {
                continue;
            };
            self.entries.insert(
                key,
                Entry {
                    zh,
                    en,
                    commit_day: day,
                    commit_votes: votes,
                    updated_at: at,
                },
            );
            imported += 1;
        }
        imported
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DAY: u64 = 86_400;

    #[test]
    fn empty_memory_decides_nothing() {
        let m = AppModeMemory::new();
        assert_eq!(m.decide("com.example.app", 1_000), None);
        assert!(m.is_empty());
    }

    #[test]
    fn single_manual_toggle_establishes_preference() {
        let mut m = AppModeMemory::new();
        assert!(m.observe("com.apple.Terminal", false, true, 1_000));
        assert_eq!(m.decide("com.apple.Terminal", 1_000), Some(false));
        // 三天以后依然成立（3.0 → 约 2.6，仍在门槛上）
        assert_eq!(m.decide("com.apple.Terminal", 1_000 + 3 * DAY), Some(false));
    }

    #[test]
    fn opposite_toggles_cancel_out() {
        let mut m = AppModeMemory::new();
        m.observe("app", false, true, 1_000);
        m.observe("app", true, true, 1_100);
        assert_eq!(m.decide("app", 1_200), None);
    }

    #[test]
    fn majority_needs_two_to_one_advantage() {
        let mut m = AppModeMemory::new();
        m.observe("app", true, true, 1_000);
        m.observe("app", true, true, 1_000);
        m.observe("app", false, true, 1_000);
        // 6.0 对 3.0，优势比恰好 2.0 → 判中文
        assert_eq!(m.decide("app", 1_000), Some(true));
    }

    #[test]
    fn old_votes_fade_after_half_lives() {
        let mut m = AppModeMemory::new();
        m.observe("app", false, true, 1_000);
        // 约四个半衰期后，3.0 衰减到 0.19，不足以支撑判定
        assert_eq!(m.decide("app", 1_000 + 4 * 14 * DAY), None);
    }

    #[test]
    fn commit_votes_are_weak_and_daily_capped() {
        let mut m = AppModeMemory::new();
        m.observe("app", true, true, DAY); // 手动定下中文
        for i in 0..10 {
            m.observe("app", false, false, DAY + i); // 同一天狂写英文
        }
        // 当天上屏票封顶 1.0，压不过 3.0 的手动票
        assert_eq!(m.decide("app", DAY + 100), Some(true));
        // 导出可见：10 次上屏只计入 1.0（封顶生效）
        let tsv = m.export_tsv();
        let votes: f32 = tsv
            .lines()
            .next()
            .unwrap()
            .split('\t')
            .nth(4)
            .unwrap()
            .parse()
            .unwrap();
        assert!((votes - 1.0).abs() < 1e-3, "上屏票应为 1.0，实际 {votes}");

        // 之后几天继续用英文：计数器跨天清零、票缓慢累积，
        // 但在追平手动票之前优势比不足 → 不判定（不折腾用户）
        m.observe("app", false, false, 2 * DAY);
        m.observe("app", false, false, 3 * DAY);
        m.observe("app", false, false, 4 * DAY);
        m.observe("app", false, false, 5 * DAY);
        assert_eq!(m.decide("app", 5 * DAY), None);
    }

    #[test]
    fn tsv_roundtrip_preserves_verdicts() {
        let mut m = AppModeMemory::new();
        m.observe("com.apple.Terminal", false, true, 1_000);
        m.observe("com.tencent.xinWeChat", true, true, 2_000);
        let tsv = m.export_tsv();
        let mut fresh = AppModeMemory::new();
        assert_eq!(fresh.import_tsv(&tsv), 2);
        assert_eq!(fresh.decide("com.apple.Terminal", 1_000), Some(false));
        assert_eq!(fresh.decide("com.tencent.xinWeChat", 2_000), Some(true));
        assert_eq!(fresh.import_tsv("坏行\n只有一列\n"), 0);
    }

    #[test]
    fn forget_removes_only_target_app() {
        let mut m = AppModeMemory::new();
        m.observe("a", true, true, 1_000);
        m.observe("b", false, true, 1_000);
        assert!(m.forget("a"));
        assert!(!m.forget("a"));
        assert_eq!(m.decide("a", 1_000), None);
        assert_eq!(m.decide("b", 1_000), Some(false));
        m.forget_all();
        assert!(m.is_empty());
    }

    #[test]
    fn rejects_bad_app_ids() {
        let mut m = AppModeMemory::new();
        assert!(!m.observe("", true, true, 1_000));
        assert!(!m.observe("  ", true, true, 1_000));
        assert!(!m.observe("a\tb", true, true, 1_000));
        assert!(!m.observe("a\nb", true, true, 1_000));
        assert!(m.is_empty());
    }

    #[test]
    fn trims_whitespace_around_bundle_id() {
        let mut m = AppModeMemory::new();
        assert!(m.observe("  app.id  ", true, true, 1_000));
        assert_eq!(m.decide("app.id", 1_000), Some(true));
    }

    #[test]
    fn max_entries_evicts_oldest() {
        let mut m = AppModeMemory::new();
        for i in 0..(MAX_ENTRIES as u64) {
            m.observe(&format!("app{i}"), true, true, 1_000 + i);
        }
        assert_eq!(m.len(), MAX_ENTRIES);
        m.observe("app-new", true, true, 9_999);
        assert_eq!(m.len(), MAX_ENTRIES);
        // 最久未更新的 app0 被挤掉
        assert_eq!(m.decide("app0", 9_999), None);
        assert_eq!(m.decide("app-new", 9_999), Some(true));
    }
}
