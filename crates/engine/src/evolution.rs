//! 知你（Know-You）自进化框架 · 决策层：上下文赌动机（ADR-0008）。
//!
//! 回答一个问题：在这个上下文里，这个词该往前挪还是往后挪？
//! 纯逻辑、零依赖、全本地：只有「(词, 特征) → 亲和度」的指数滑动账本，
//! 没有模型、没有推理。奖励来自真实行为（选词/纠错/重选），
//! 调整永远封顶——学习只能微调排序，不能掀桌。

use std::collections::HashMap;

/// 亲和度半衰期：14 天（与按应用记忆一致）。
pub const HALF_LIFE_SECS: f64 = 14.0 * 24.0 * 3600.0;
/// 学习率：每次奖励把账本向该奖励滑动这么多。
pub const LR: f32 = 0.35;
/// 置信门槛：观察少于这个数不参与排序（防单次误选劫持）。
pub const MIN_OBS: u32 = 2;
/// 单词总修正封顶：学习只能微调，base 分仍是词频与整句概率。
pub const MAX_ADJUST: f32 = 3.0;
/// 账本容量：(词, 特征) 对上限，超出淘汰最久未触摸的。
pub const MAX_ENTRIES: usize = 50_000;

// 教学层奖励强度（×100 走 FFI 整数）。
pub const REWARD_SELECT: f32 = 1.0; // 正常选词
pub const REWARD_RESELECT: f32 = 1.5; // 删除后重新选中：真实意图
pub const REWARD_DELETED: f32 = -2.0; // 选了又删：明确打脸
pub const REWARD_ALT_RANK: f32 = 0.6; // 数字键选了第 2+ 候选

/// 一个 (词, 特征) 的账本格。
#[derive(Debug, Clone, Copy, Default, PartialEq)]
struct Cell {
    v: f32,
    n: u32,
    last: u64,
}

/// 上下文赌动机账本。
#[derive(Debug, Default)]
pub struct EvolutionMemory {
    cells: HashMap<(String, String), Cell>,
}

fn decay(v: f32, from: u64, now: u64) -> f32 {
    if now <= from {
        return v;
    }
    let dt = (now - from) as f64;
    ((v as f64) * 0.5f64.powf(dt / HALF_LIFE_SECS)) as f32
}

/// 从信号栈提取决策特征：词法窗（最近上屏）+ 应用 + 时段。
/// 词法窗贡献：每个字一个单字特征 + 末两字 bigram（越靠后影响越大是 Viterbi 的事，
/// 这里保持无序集合，让账本自己学会哪个维度重要）。
pub fn context_features(lex_window: &str, app: Option<&str>, hour: u32) -> Vec<String> {
    let mut f = Vec::new();
    let chars: Vec<char> = lex_window.chars().rev().take(4).collect();
    for &c in &chars {
        f.push(format!("lex:{c}"));
    }
    if chars.len() >= 2 {
        f.push(format!("lex2:{}{}", chars[1], chars[0]));
    }
    if let Some(a) = app {
        let a = a.trim();
        if !a.is_empty() {
            f.push(format!("app:{a}"));
        }
    }
    let tod = match hour {
        6..=10 => "morning",
        11..=13 => "noon",
        14..=18 => "afternoon",
        _ => "night",
    };
    f.push(format!("tod:{tod}"));
    f
}

/// FNV-1a：主题指纹的哈希底座。
fn fnv1a(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for &b in bytes {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

/// 主题指纹：最近窗口文本的每个字哈希进 16 个桶，取票数最高的 `k` 个。
/// 没有语义、没有模型——账本自己学会「这个桶里我常想要哪个词」。
pub fn topic_features(window: &str, k: usize) -> Vec<String> {
    const BUCKETS: usize = 16;
    let mut votes = [0u32; BUCKETS];
    for c in window.chars() {
        let b = (fnv1a(c.encode_utf8(&mut [0u8; 4]).as_bytes()) % BUCKETS as u64) as usize;
        votes[b] += 1;
    }
    let mut order: Vec<usize> = (0..BUCKETS).collect();
    order.sort_by(|&a, &b| votes[b].cmp(&votes[a]));
    order
        .into_iter()
        .filter(|&b| votes[b] > 0)
        .take(k)
        .map(|b| format!("topic:{b}"))
        .collect()
}

impl EvolutionMemory {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn len(&self) -> usize {
        self.cells.len()
    }

    pub fn is_empty(&self) -> bool {
        self.cells.is_empty()
    }

    /// 记录一次奖励：把 (词, 每个上下文特征) 的账本向奖励值滑动。
    pub fn reward(&mut self, word: &str, features: &[String], r: f32, now: u64) {
        let word = word.trim();
        if word.is_empty() {
            return;
        }
        for f in features {
            let cell = self.cells.entry((word.to_string(), f.clone())).or_default();
            cell.v = decay(cell.v, cell.last, now);
            cell.v += LR * (r - cell.v);
            cell.n += 1;
            cell.last = now;
        }
        self.evict();
    }

    fn evict(&mut self) {
        if self.cells.len() <= MAX_ENTRIES {
            return;
        }
        let oldest = self
            .cells
            .iter()
            .min_by_key(|(_, c)| c.last)
            .map(|(k, _)| k.clone());
        if let Some(k) = oldest {
            self.cells.remove(&k);
        }
    }

    /// 单特征的当前亲和度（含衰减与置信门槛）。
    fn affinity(&self, word: &str, f: &str, now: u64) -> Option<f32> {
        let c = self.cells.get(&(word.to_string(), f.to_string()))?;
        if c.n < MIN_OBS {
            return None;
        }
        Some(decay(c.v, c.last, now))
    }

    /// 对候选列表施加学习修正并按修正后分数降序排列。
    /// 输入 `(词, base 分)`；封顶 ±MAX_ADJUST，base 分排序稳定性由调用方保证。
    pub fn adjust(&self, scores: &mut [(String, f32)], features: &[String], now: u64) {
        for (word, score) in scores.iter_mut() {
            let mut delta = 0.0f32;
            for f in features {
                if let Some(a) = self.affinity(word, f, now) {
                    delta += a;
                }
            }
            *score += delta.clamp(-MAX_ADJUST, MAX_ADJUST);
        }
        scores.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    }

    /// 同 [`Self::adjust`]，但返回 `(词, 修正后分数, 实际施加的 delta)`——
    /// delta 供前端做决策轨道展示。
    pub fn rank(
        &self,
        scores: &[(String, f32)],
        features: &[String],
        now: u64,
    ) -> Vec<(String, f32, f32)> {
        let mut out: Vec<(String, f32, f32)> = scores
            .iter()
            .map(|(word, base)| {
                let mut delta = 0.0f32;
                for f in features {
                    if let Some(a) = self.affinity(word, f, now) {
                        delta += a;
                    }
                }
                let delta = delta.clamp(-MAX_ADJUST, MAX_ADJUST);
                (word.clone(), base + delta, delta)
            })
            .collect();
        out.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        out
    }

    /// 决策轨道：这个词为什么被挪动——返回有贡献的特征与各自亲和度。
    pub fn explain(&self, word: &str, features: &[String], now: u64) -> Vec<(String, f32)> {
        let mut out: Vec<(String, f32)> = features
            .iter()
            .filter_map(|f| self.affinity(word, f, now).map(|a| (f.clone(), a)))
            .collect();
        out.sort_by(|a, b| b.1.abs().partial_cmp(&a.1.abs()).unwrap_or(std::cmp::Ordering::Equal));
        out
    }

    pub fn export_tsv(&self) -> String {
        if self.cells.is_empty() {
            return String::new();
        }
        let mut rows: Vec<String> = self
            .cells
            .iter()
            .map(|((w, f), c)| format!("{w}\t{f}\t{:.4}\t{}\t{}", c.v, c.n, c.last))
            .collect();
        rows.sort();
        rows.join("\n") + "\n"
    }

    /// 导入 TSV；坏行跳过，返回成功行数。
    pub fn import_tsv(&mut self, tsv: &str) -> usize {
        let mut n = 0;
        for line in tsv.lines() {
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() != 5 {
                continue;
            }
            let (Ok(v), Ok(cnt), Ok(last)) = (
                f[2].parse::<f32>(),
                f[3].parse::<u32>(),
                f[4].parse::<u64>(),
            ) else {
                continue;
            };
            if f[0].is_empty() || f[1].is_empty() {
                continue;
            }
            self.cells
                .insert((f[0].to_string(), f[1].to_string()), Cell { v, n: cnt, last });
            n += 1;
        }
        n
    }

    pub fn forget_all(&mut self) {
        self.cells.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn features() -> Vec<String> {
        context_features("优先", Some("com.apple.Notes"), 10)
    }

    #[test]
    fn no_observations_means_identity() {
        let m = EvolutionMemory::new();
        let mut s = vec![("现".to_string(), 10.0), ("先".to_string(), 9.0)];
        m.adjust(&mut s, &features(), 1_000);
        assert_eq!(s[0].0, "现");
        assert_eq!(s[1].1, 9.0);
    }

    #[test]
    fn single_reward_is_not_enough() {
        let mut m = EvolutionMemory::new();
        m.reward("先", &features(), REWARD_SELECT, 1_000);
        let mut s = vec![("现".to_string(), 10.0), ("先".to_string(), 9.0)];
        m.adjust(&mut s, &features(), 1_000);
        assert_eq!(s[0].0, "现"); // 一次观察不说话
    }

    #[test]
    fn two_selects_flip_the_order() {
        let mut m = EvolutionMemory::new();
        m.reward("先", &features(), REWARD_SELECT, 1_000);
        m.reward("先", &features(), REWARD_SELECT, 1_100);
        // v = 1 + 0.35*(1-1) = 1（第二次已收敛到 1.0 附近，实际 1+0.35*0=1）
        let mut s = vec![("现".to_string(), 10.0), ("先".to_string(), 9.0)];
        m.adjust(&mut s, &features(), 1_200);
        assert_eq!(s[0].0, "先", "两次选择后先应上浮: {:?}", s);
    }

    #[test]
    fn correction_beats_selection() {
        let mut m = EvolutionMemory::new();
        // 在这个上下文里先选了现、又删了改选先：现吃强负，先吃强正
        m.reward("现", &features(), REWARD_SELECT, 1_000);
        m.reward("现", &features(), REWARD_DELETED, 1_050);
        m.reward("先", &features(), REWARD_RESELECT, 1_060);
        let mut s = vec![("现".to_string(), 10.0), ("先".to_string(), 9.0)];
        m.adjust(&mut s, &features(), 1_100);
        assert_eq!(s[0].0, "先", "纠错应压过第一次错选: {:?}", s);
    }

    #[test]
    fn adjustment_is_capped() {
        let mut m = EvolutionMemory::new();
        for i in 0..20 {
            m.reward("县", &features(), REWARD_SELECT, 1_000 + i);
        }
        let mut s = vec![("县".to_string(), 1.0), ("现".to_string(), 50.0)];
        m.adjust(&mut s, &features(), 2_000);
        let county = s.iter().find(|(w, _)| w == "县").unwrap().1;
        assert!(
            county <= 1.0 + MAX_ADJUST + 1e-4,
            "修正必须封顶: 县={county}, all={s:?}"
        );
    }

    #[test]
    fn old_affinity_fades_away() {
        let mut m = EvolutionMemory::new();
        for i in 0..3 {
            m.reward("先", &features(), REWARD_SELECT, 1_000 + i);
        }
        let four_halves = 1_000 + (4.0 * HALF_LIFE_SECS) as u64;
        let mut s = vec![("先".to_string(), 9.0), ("现".to_string(), 9.5)];
        m.adjust(&mut s, &features(), four_halves);
        assert_eq!(s[0].0, "现", "四个半衰期后不再干预: {:?}", s);
    }

    #[test]
    fn context_matters_same_word_different_features() {
        let mut m = EvolutionMemory::new();
        let notes = features();
        let terminal = context_features("git ", Some("com.apple.Terminal"), 22);
        for i in 0..3 {
            m.reward("先", &notes, REWARD_SELECT, 1_000 + i);
        }
        for i in 0..3 {
            m.reward("西安", &terminal, REWARD_SELECT, 1_000 + i);
        }
        let mut in_notes = vec![("先".to_string(), 9.0), ("西安".to_string(), 9.0)];
        m.adjust(&mut in_notes, &notes, 2_000);
        let mut in_term = vec![("先".to_string(), 9.0), ("西安".to_string(), 9.0)];
        m.adjust(&mut in_term, &terminal, 2_000);
        assert_eq!(in_notes[0].0, "先");
        assert_eq!(in_term[0].0, "西安");
    }

    #[test]
    fn explain_reports_contributing_features() {
        let mut m = EvolutionMemory::new();
        for i in 0..3 {
            m.reward("先", &features(), REWARD_SELECT, 1_000 + i);
        }
        let trail = m.explain("先", &features(), 1_500);
        assert!(!trail.is_empty());
        assert!(trail.iter().any(|(f, v)| f.starts_with("lex:") && *v > 0.0));
    }

    #[test]
    fn tsv_roundtrip_keeps_verdicts() {
        let mut m = EvolutionMemory::new();
        for i in 0..3 {
            m.reward("先", &features(), REWARD_SELECT, 1_000 + i);
        }
        let tsv = m.export_tsv();
        let mut fresh = EvolutionMemory::new();
        assert!(fresh.import_tsv(&tsv) >= 1);
        let mut s = vec![("现".to_string(), 10.0), ("先".to_string(), 9.0)];
        fresh.adjust(&mut s, &features(), 1_200);
        assert_eq!(s[0].0, "先");
        assert_eq!(fresh.import_tsv("坏行\n少\t列\n"), 0);
    }

    #[test]
    fn topic_buckets_are_stable_and_ordered() {
        let a = topic_features("县政府关于经济开发区的通知", 3);
        let b = topic_features("县政府关于经济开发区的通知", 3);
        assert_eq!(a, b);
        assert!(a.len() <= 3);
        assert!(topic_features("", 3).is_empty());
    }

    #[test]
    fn empty_words_are_ignored() {
        let mut m = EvolutionMemory::new();
        m.reward("  ", &features(), REWARD_SELECT, 1_000);
        assert!(m.is_empty());
    }
}
