//! 用户词学习模型。M0 仅内存；M1 起由前端加密落盘（密钥在系统钥匙串）。

use std::collections::HashMap;

#[derive(Default, Debug, Clone)]
pub struct UserModel {
    counts: HashMap<String, u32>,
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

    pub fn count(&self, text: &str) -> u32 {
        self.counts.get(text).copied().unwrap_or(0)
    }

    /// 重排加分：对数增长，避免个别词完全压过语言模型。
    pub fn bonus(&self, text: &str) -> f64 {
        let c = self.count(text);
        if c == 0 { 0.0 } else { 1.0 + (c as f64).ln() }
    }

    pub fn len(&self) -> usize {
        self.counts.len()
    }

    pub fn is_empty(&self) -> bool {
        self.counts.is_empty()
    }

    pub fn clear(&mut self) {
        self.counts.clear();
    }

    /// 导出为 TSV（`词\t次数`），供加密存储层使用。
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
        out
    }

    /// 导入 TSV，返回成功条目数。
    pub fn import_tsv(&mut self, s: &str) -> usize {
        let mut n = 0;
        for line in s.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut it = line.splitn(2, '\t');
            let (Some(w), Some(c)) = (it.next(), it.next()) else {
                continue;
            };
            let Ok(c) = c.trim().parse::<u32>() else {
                continue;
            };
            if w.is_empty() {
                continue;
            }
            self.counts.insert(w.to_string(), c);
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
}
