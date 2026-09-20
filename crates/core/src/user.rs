//! 用户词学习模型。M0 仅内存；M1 起由前端加密落盘（密钥在系统钥匙串）。
//!
//! 这是「L0 内置统计模型」：词频 + 二元组（上一个上屏词 → 当前候选）重排，
//! 零下载、零额外内存开销（上限受 `MAX_PAIRS` 约束，超出后衰减）。

use std::collections::HashMap;

/// 二元组条数上限；超出后丢弃只出现过一次的组合并把计数减半。
const MAX_PAIRS: usize = 20_000;

#[derive(Default, Debug, Clone)]
pub struct UserModel {
    counts: HashMap<String, u32>,
    /// prev -> next -> 次数
    pairs: HashMap<String, HashMap<String, u32>>,
    pair_len: usize,
}

impl UserModel {
    pub fn new() -> Self {
        Self::default()
    }

    /// 用户选词后调用，用于下次重排。
    pub fn record(&mut self, text: &str) {
        if text.is_empty() {
            return;
        }
        let c = self.counts.entry(text.to_string()).or_insert(0);
        *c = c.saturating_add(1);
    }

    /// 记录「上一个上屏词 → 本次上屏词」，用于下一句的候选预测。
    pub fn record_pair(&mut self, prev: &str, next: &str) {
        if prev.is_empty() || next.is_empty() || prev == next {
            return;
        }
        let entry = self
            .pairs
            .entry(prev.to_string())
            .or_default()
            .entry(next.to_string())
            .or_insert(0);
        if *entry == 0 {
            self.pair_len += 1;
        }
        *entry = entry.saturating_add(1);
        if self.pair_len > MAX_PAIRS {
            self.decay_pairs();
        }
    }

    fn decay_pairs(&mut self) {
        self.pairs.retain(|_, nexts| {
            nexts.retain(|_, c| {
                if *c > 1 {
                    *c /= 2;
                    true
                } else {
                    false
                }
            });
            !nexts.is_empty()
        });
        self.pair_len = self.pairs.values().map(HashMap::len).sum();
    }

    pub fn count(&self, text: &str) -> u32 {
        self.counts.get(text).copied().unwrap_or(0)
    }

    pub fn pair_count(&self, prev: &str, next: &str) -> u32 {
        self.pairs
            .get(prev)
            .and_then(|m| m.get(next))
            .copied()
            .unwrap_or(0)
    }

    pub fn pair_len(&self) -> usize {
        self.pair_len
    }

    /// 重排加分：对数增长，避免个别词完全压过语言模型。
    pub fn bonus(&self, text: &str) -> f64 {
        let c = self.count(text);
        if c == 0 { 0.0 } else { 1.0 + (c as f64).ln() }
    }

    /// 二元组加分：能跨过常见词频差（ln 2~3），但设上限避免过度自信。
    pub fn pair_bonus(&self, prev: &str, next: &str) -> f64 {
        let c = self.pair_count(prev, next);
        if c == 0 {
            0.0
        } else {
            (1.5 * (c as f64 + 1.0).ln()).min(8.0)
        }
    }

    pub fn len(&self) -> usize {
        self.counts.len()
    }

    pub fn is_empty(&self) -> bool {
        self.counts.is_empty() && self.pairs.is_empty()
    }

    pub fn clear(&mut self) {
        self.counts.clear();
        self.pairs.clear();
        self.pair_len = 0;
    }

    /// 导出为 TSV：`词\t次数`；二元组行为 `@pair\t前词\t后词\t次数`，供加密存储层使用。
    pub fn export_tsv(&self) -> String {
        let mut keys: Vec<_> = self.counts.iter().collect();
        keys.sort_by(|a, b| a.0.cmp(b.0));
        let mut out = String::new();
        for (w, c) in keys {
            out.push_str(w);
            out.push('\t');
            out.push_str(&c.to_string());
            out.push('\n');
        }
        let mut prevs: Vec<_> = self.pairs.iter().collect();
        prevs.sort_by(|a, b| a.0.cmp(b.0));
        for (prev, nexts) in prevs {
            let mut ns: Vec<_> = nexts.iter().collect();
            ns.sort_by(|a, b| a.0.cmp(b.0));
            for (next, c) in ns {
                out.push_str("@pair\t");
                out.push_str(prev);
                out.push('\t');
                out.push_str(next);
                out.push('\t');
                out.push_str(&c.to_string());
                out.push('\n');
            }
        }
        out
    }

    /// 导入 TSV，返回成功条目数（词 + 二元组）。
    pub fn import_tsv(&mut self, s: &str) -> usize {
        let mut n = 0;
        for line in s.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut it = line.split('\t');
            let Some(first) = it.next() else { continue };
            if first == "@pair" {
                let (Some(prev), Some(next), Some(c)) = (it.next(), it.next(), it.next()) else {
                    continue;
                };
                let Ok(c) = c.trim().parse::<u32>() else {
                    continue;
                };
                if prev.is_empty() || next.is_empty() {
                    continue;
                }
                let entry = self
                    .pairs
                    .entry(prev.to_string())
                    .or_default()
                    .entry(next.to_string())
                    .or_insert(0);
                if *entry == 0 {
                    self.pair_len += 1;
                }
                *entry = c;
                n += 1;
                continue;
            }
            let Some(c) = it.next() else { continue };
            let Ok(c) = c.trim().parse::<u32>() else {
                continue;
            };
            if first.is_empty() {
                continue;
            }
            self.counts.insert(first.to_string(), c);
            n += 1;
        }
        n
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_and_bonus() {
        let mut u = UserModel::new();
        assert_eq!(u.bonus("你好"), 0.0);
        u.record("你好");
        assert_eq!(u.count("你好"), 1);
        let b1 = u.bonus("你好");
        u.record("你好");
        assert!(u.bonus("你好") > b1);
        assert_eq!(u.len(), 1);
    }

    #[test]
    fn tsv_roundtrip() {
        let mut u = UserModel::new();
        u.record("你好");
        u.record("你好");
        u.record("世界");
        let s = u.export_tsv();
        let mut v = UserModel::new();
        assert_eq!(v.import_tsv(&s), 2);
        assert_eq!(v.count("你好"), 2);
        assert_eq!(v.count("世界"), 1);
    }

    #[test]
    fn import_tolerates_garbage() {
        let mut u = UserModel::new();
        let n = u.import_tsv("# 注释\n\n坏行\n好\t3\nx\tNaN\n");
        assert_eq!(n, 1);
        assert_eq!(u.count("好"), 3);
    }

    #[test]
    fn pair_bonus_grows_and_is_capped() {
        let mut u = UserModel::new();
        assert_eq!(u.pair_bonus("北京", "世界"), 0.0);
        u.record_pair("北京", "世界");
        let b1 = u.pair_bonus("北京", "世界");
        assert!(b1 > 0.0);
        for _ in 0..500 {
            u.record_pair("北京", "世界");
        }
        assert!(u.pair_bonus("北京", "世界") > b1);
        assert!(u.pair_bonus("北京", "世界") <= 8.0);
        assert_eq!(u.pair_len(), 1);
    }

    #[test]
    fn pair_tsv_roundtrip() {
        let mut u = UserModel::new();
        u.record("北京");
        u.record_pair("北京", "世界");
        u.record_pair("北京", "世界");
        let s = u.export_tsv();
        assert!(s.contains("@pair\t北京\t世界\t2"), "{s}");
        let mut v = UserModel::new();
        let n = v.import_tsv(&s);
        assert_eq!(n, 2);
        assert_eq!(v.count("北京"), 1);
        assert_eq!(v.pair_count("北京", "世界"), 2);
    }

    #[test]
    fn pair_decay_keeps_frequent() {
        let mut u = UserModel::new();
        u.record_pair("a", "b");
        u.record_pair("a", "b");
        u.record_pair("c", "d");
        u.pair_len = MAX_PAIRS + 1; // 模拟超限
        u.decay_pairs();
        assert_eq!(u.pair_count("a", "b"), 1);
        assert_eq!(u.pair_count("c", "d"), 0);
    }
}
