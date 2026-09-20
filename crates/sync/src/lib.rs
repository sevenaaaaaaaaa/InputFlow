//! 同步合并内核（无网络）。
//!
//! 设计目标：**乱序、重复、断连**都安全。所有合并规则满足交换律、结合律、幂等，
//! 因此设备之间可以任意顺序交换 op-log，最终一致。
//!
//! - 词频增量：按副本保存的 LWW 计数器（G-Counter 的 LWW 变体），合并取各副本最大值再求和。
//! - 设置/剪切板：LWW 寄存器，用 [`Hlc`] 定序，平局比 device id。
//! - 词库新增：LWW per (key, word)，取较新 Hlc。
//!
//! 传输层（QUIC + TLS 1.3 + mDNS）与配对流程见 `docs/sync-protocol.md`（M1）。

use std::collections::HashMap;

/// 混合逻辑时钟：不依赖可信时钟也能定序。
#[derive(Clone, PartialEq, Eq, Hash, Debug)]
pub struct Hlc {
    pub wall_ms: u64,
    pub counter: u32,
    pub device: String,
}

impl Hlc {
    pub fn new(wall_ms: u64, device: impl Into<String>) -> Self {
        Self {
            wall_ms,
            counter: 0,
            device: device.into(),
        }
    }

    /// 本地事件：确保严格递增。
    pub fn tick(&self, now_ms: u64) -> Self {
        if now_ms > self.wall_ms {
            Self::new(now_ms, self.device.clone())
        } else {
            Self {
                wall_ms: self.wall_ms,
                counter: self.counter + 1,
                device: self.device.clone(),
            }
        }
    }

    /// 收到远端事件后的本地时钟推进。
    pub fn merge(&self, remote: &Hlc, now_ms: u64) -> Self {
        if remote.wall_ms > self.wall_ms {
            Self {
                wall_ms: remote.wall_ms,
                counter: remote.counter + 1,
                device: self.device.clone(),
            }
        } else if remote.wall_ms == self.wall_ms {
            Self {
                wall_ms: self.wall_ms,
                counter: self.counter.max(remote.counter) + 1,
                device: self.device.clone(),
            }
        } else {
            self.tick(now_ms)
        }
    }
}

impl Ord for Hlc {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.wall_ms
            .cmp(&other.wall_ms)
            .then_with(|| self.counter.cmp(&other.counter))
            .then_with(|| self.device.cmp(&other.device))
    }
}

impl PartialOrd for Hlc {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

/// 同步操作。
#[derive(Clone, PartialEq, Debug)]
pub enum Op {
    /// 用户词频增量（按副本记录，重复投递无副作用）
    WordFreq {
        key: String,
        word: String,
        delta: i64,
        at: Hlc,
    },
    /// 词库新增
    WordBookAdd {
        key: String,
        word: String,
        freq: u32,
        at: Hlc,
    },
    /// 设置项（LWW）
    Setting { key: String, value: String, at: Hlc },
    /// 剪切板条目（LWW + 墓碑）
    Clipboard {
        id: String,
        text: String,
        deleted: bool,
        at: Hlc,
    },
}

impl Op {
    pub fn at(&self) -> &Hlc {
        match self {
            Op::WordFreq { at, .. }
            | Op::WordBookAdd { at, .. }
            | Op::Setting { at, .. }
            | Op::Clipboard { at, .. } => at,
        }
    }
}

/// 合并后的状态。
#[derive(Default, Debug, Clone, PartialEq)]
pub struct Store {
    /// (key, word) → 副本 → (Hlc, delta)
    freq: HashMap<(String, String), HashMap<String, (Hlc, i64)>>,
    book: HashMap<(String, String), (Hlc, u32)>,
    settings: HashMap<String, (Hlc, String)>,
    clipboard: HashMap<String, (Hlc, String, bool)>,
}

impl Store {
    pub fn new() -> Self {
        Self::default()
    }

    /// 应用一条 op（幂等；重复投递结果不变）。
    pub fn apply(&mut self, op: &Op) {
        match op {
            Op::WordFreq {
                key,
                word,
                delta,
                at,
            } => {
                let slot = self
                    .freq
                    .entry((key.clone(), word.clone()))
                    .or_default()
                    .entry(at.device.clone())
                    .or_insert_with(|| (at.clone(), *delta));
                if at > &slot.0 {
                    *slot = (at.clone(), *delta);
                }
            }
            Op::WordBookAdd {
                key,
                word,
                freq,
                at,
            } => {
                let slot = self
                    .book
                    .entry((key.clone(), word.clone()))
                    .or_insert_with(|| (at.clone(), *freq));
                if at > &slot.0 {
                    *slot = (at.clone(), *freq);
                } else if at == &slot.0 && *freq > slot.1 {
                    slot.1 = *freq;
                }
            }
            Op::Setting { key, value, at } => {
                let slot = self
                    .settings
                    .entry(key.clone())
                    .or_insert_with(|| (at.clone(), value.clone()));
                if at > &slot.0 {
                    *slot = (at.clone(), value.clone());
                }
            }
            Op::Clipboard {
                id,
                text,
                deleted,
                at,
            } => {
                let slot = self
                    .clipboard
                    .entry(id.clone())
                    .or_insert_with(|| (at.clone(), text.clone(), *deleted));
                if at > &slot.0 {
                    *slot = (at.clone(), text.clone(), *deleted);
                }
            }
        }
    }

    /// 合并另一份状态（各字段按各自规则取并）。
    pub fn merge(&mut self, other: &Store) {
        for (k, replicas) in &other.freq {
            let slot = self.freq.entry(k.clone()).or_default();
            for (device, (at, delta)) in replicas {
                let e = slot
                    .entry(device.clone())
                    .or_insert_with(|| (at.clone(), *delta));
                if at > &e.0 {
                    *e = (at.clone(), *delta);
                }
            }
        }
        for (k, (at, freq)) in &other.book {
            let e = self
                .book
                .entry(k.clone())
                .or_insert_with(|| (at.clone(), *freq));
            if at > &e.0 || (at == &e.0 && *freq > e.1) {
                *e = (at.clone(), *freq);
            }
        }
        for (k, (at, v)) in &other.settings {
            let e = self
                .settings
                .entry(k.clone())
                .or_insert_with(|| (at.clone(), v.clone()));
            if at > &e.0 {
                *e = (at.clone(), v.clone());
            }
        }
        for (k, (at, text, deleted)) in &other.clipboard {
            let e = self
                .clipboard
                .entry(k.clone())
                .or_insert_with(|| (at.clone(), text.clone(), *deleted));
            if at > &e.0 {
                *e = (at.clone(), text.clone(), *deleted);
            }
        }
    }

    /// 合并后的词频：各副本增量求和。
    pub fn word_freq(&self, key: &str, word: &str) -> i64 {
        self.freq
            .get(&(key.to_string(), word.to_string()))
            .map(|m| m.values().map(|(_, d)| *d).sum())
            .unwrap_or(0)
    }

    pub fn word_book(&self, key: &str, word: &str) -> Option<u32> {
        self.book
            .get(&(key.to_string(), word.to_string()))
            .map(|(_, f)| *f)
    }

    pub fn setting(&self, key: &str) -> Option<&str> {
        self.settings.get(key).map(|(_, v)| v.as_str())
    }

    /// 剪切板（不含墓碑），按 Hlc 新→旧。
    pub fn clipboard(&self) -> Vec<(&str, &str)> {
        let mut items: Vec<(&Hlc, &str, &str, bool)> = self
            .clipboard
            .iter()
            .map(|(id, (at, text, deleted))| (at, id.as_str(), text.as_str(), *deleted))
            .collect();
        items.sort_by(|a, b| b.0.cmp(a.0));
        items
            .into_iter()
            .filter(|(_, _, _, deleted)| !*deleted)
            .map(|(_, id, text, _)| (id, text))
            .collect()
    }

    pub fn clipboard_len(&self) -> usize {
        self.clipboard().len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn op_freq(device: &str, wall: u64, delta: i64) -> Op {
        Op::WordFreq {
            key: "ni'hao".into(),
            word: "你好".into(),
            delta,
            at: Hlc::new(wall, device),
        }
    }

    #[test]
    fn hlc_is_monotonic() {
        let a = Hlc::new(1000, "A");
        let b = a.tick(900);
        let c = b.tick(1000);
        let d = c.tick(2000);
        assert!(a < b && b < c && c < d);
        assert_eq!(d.wall_ms, 2000);
    }

    #[test]
    fn hlc_merge_advances() {
        let local = Hlc::new(100, "A");
        let remote = Hlc::new(500, "B");
        let merged = local.merge(&remote, 200);
        assert!(merged > remote, "merge 后本地时钟必须领先远端");
    }

    #[test]
    fn freq_counters_sum_and_are_idempotent() {
        let mut s = Store::new();
        s.apply(&op_freq("A", 10, 3));
        s.apply(&op_freq("A", 10, 3)); // 重复投递
        s.apply(&op_freq("B", 20, 5));
        assert_eq!(s.word_freq("ni'hao", "你好"), 8);
    }

    #[test]
    fn merge_is_commutative_and_idempotent() {
        let ops = vec![
            op_freq("A", 10, 3),
            op_freq("B", 12, 5),
            Op::Setting {
                key: "mode".into(),
                value: "flypy".into(),
                at: Hlc::new(10, "A"),
            },
            Op::Setting {
                key: "mode".into(),
                value: "zrm".into(),
                at: Hlc::new(11, "B"),
            },
            Op::Clipboard {
                id: "c1".into(),
                text: "秘密".into(),
                deleted: false,
                at: Hlc::new(10, "A"),
            },
        ];

        let mut a = Store::new();
        for op in &ops {
            a.apply(op);
        }
        let mut b = Store::new();
        for op in ops.iter().rev() {
            b.apply(op);
        }
        assert_eq!(a, b, "应用顺序不应影响结果");
        assert_eq!(a.setting("mode"), Some("zrm"));
        assert_eq!(a.word_freq("ni'hao", "你好"), 8);

        let mut c = a.clone();
        c.merge(&c.clone());
        assert_eq!(c, a, "自合并必须是幂等的");
    }

    #[test]
    fn concurrent_store_merge_matches_direct_apply() {
        let ops_a = vec![op_freq("A", 10, 3), op_freq("A", 11, 1)];
        let ops_b = vec![op_freq("B", 10, 5)];
        let mut a = Store::new();
        for op in &ops_a {
            a.apply(op);
        }
        let mut b = Store::new();
        for op in &ops_b {
            b.apply(op);
        }
        let mut merged = a.clone();
        merged.merge(&b);
        let mut direct = Store::new();
        for op in ops_a.iter().chain(ops_b.iter()) {
            direct.apply(op);
        }
        assert_eq!(merged, direct);
    }

    #[test]
    fn clipboard_last_write_wins_and_tombstone() {
        let mut s = Store::new();
        s.apply(&Op::Clipboard {
            id: "c1".into(),
            text: "v1".into(),
            deleted: false,
            at: Hlc::new(10, "A"),
        });
        s.apply(&Op::Clipboard {
            id: "c1".into(),
            text: "v2".into(),
            deleted: false,
            at: Hlc::new(20, "B"),
        });
        assert_eq!(s.clipboard(), vec![("c1", "v2")]);
        s.apply(&Op::Clipboard {
            id: "c1".into(),
            text: String::new(),
            deleted: true,
            at: Hlc::new(30, "A"),
        });
        assert!(s.clipboard().is_empty());
    }

    #[test]
    fn stale_op_does_not_override_newer() {
        let mut s = Store::new();
        s.apply(&Op::Setting {
            key: "k".into(),
            value: "new".into(),
            at: Hlc::new(100, "A"),
        });
        s.apply(&Op::Setting {
            key: "k".into(),
            value: "old".into(),
            at: Hlc::new(50, "B"),
        });
        assert_eq!(s.setting("k"), Some("new"));
    }

    #[test]
    fn word_book_lww() {
        let mut s = Store::new();
        s.apply(&Op::WordBookAdd {
            key: "ni".into(),
            word: "你".into(),
            freq: 1,
            at: Hlc::new(10, "A"),
        });
        s.apply(&Op::WordBookAdd {
            key: "ni".into(),
            word: "你".into(),
            freq: 9,
            at: Hlc::new(20, "B"),
        });
        assert_eq!(s.word_book("ni", "你"), Some(9));
    }
}
