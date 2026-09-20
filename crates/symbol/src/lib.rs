//! 符号输入：全拼模式下 `u` 前缀触发，按拼音/英文关键词检索常用符号。
//!
//! 为什么是 `u`：普通话里没有以 `u` 开头的音节（`wu` 才是），所以 `u` 前缀
//! 不会和正常拼音抢输入；这也是 fcitx5 unicode addon 的思路。
//!
//! `u` 单独按下展示各组精选；`ujiantou` 整组召回箭头；`uduihao` 精确到 `✓`。

use std::sync::OnceLock;

use inputflow_core::{Candidate, CandidateKind, Decoder};

mod data;

pub use data::GROUPS;

/// 触发键。
pub const TRIGGER: char = 'u';
/// 空查询（只按了 `u`）时展示的精选数量。
pub const FEATURED_COUNT: usize = 30;
/// 每组进入精选的条目数。
const FEATURED_PER_GROUP: usize = 4;
/// 单次返回上限。
const MAX_RESULTS: usize = 30;

struct Entry {
    glyph: &'static str,
    aliases: &'static str,
    label: &'static str,
    group_alias: &'static str,
    group: usize,
    index_in_group: usize,
}

fn entries() -> &'static [Entry] {
    static ENTRIES: OnceLock<Vec<Entry>> = OnceLock::new();
    ENTRIES.get_or_init(|| {
        let mut v = Vec::new();
        for (g, (_, group_alias, items)) in GROUPS.iter().enumerate() {
            for (i, (glyph, aliases, label)) in items.iter().enumerate() {
                v.push(Entry {
                    glyph,
                    aliases,
                    label,
                    group_alias,
                    group: g,
                    index_in_group: i,
                });
            }
        }
        v
    })
}

fn featured() -> Vec<usize> {
    let mut out = Vec::with_capacity(FEATURED_COUNT);
    for round in 0..FEATURED_PER_GROUP {
        for (i, e) in entries().iter().enumerate() {
            if e.index_in_group == round && out.len() < FEATURED_COUNT {
                out.push(i);
            }
        }
    }
    out
}

pub struct SymbolDecoder;

impl SymbolDecoder {
    /// 查询串不含触发键。`consumed` 按查询长度计算，由调用方补上触发键的那一位。
    pub fn candidates(&self, query: &str) -> Vec<Candidate> {
        self.build(query, query.chars().count())
    }

    /// 直接吃整个按键缓冲（必须以 `u` 开头），`consumed` 含触发键。
    pub fn decode_buffer(&self, buffer: &str) -> Vec<Candidate> {
        let mut it = buffer.chars();
        if it.next() != Some(TRIGGER) {
            return Vec::new();
        }
        let query = it.as_str();
        self.build(query, query.chars().count() + 1)
    }

    fn build(&self, query: &str, consumed: usize) -> Vec<Candidate> {
        let query = query.trim().to_ascii_lowercase();
        let all = entries();
        let picked: Vec<(f64, usize)> = if query.is_empty() {
            featured()
                .into_iter()
                .map(|i| (1.0 - i as f64 * 1e-4, i))
                .collect()
        } else {
            let mut scored: Vec<(f64, usize)> = Vec::new();
            for (i, e) in all.iter().enumerate() {
                let mut best = 0.0f64;
                for alias in e.aliases.split_whitespace() {
                    let s = if alias == query {
                        3.0
                    } else if alias.starts_with(&query) {
                        2.0
                    } else if query.len() >= 2 && alias.contains(&query) {
                        1.0
                    } else {
                        0.0
                    };
                    best = best.max(s);
                }
                for alias in e.group_alias.split_whitespace() {
                    if alias == query || (query.len() >= 2 && alias.starts_with(&query)) {
                        best = best.max(1.5);
                    }
                }
                if best > 0.0 {
                    // 同分时按组内顺序稳定排序
                    scored.push((best - (e.group * 100 + e.index_in_group) as f64 * 1e-5, i));
                }
            }
            scored.sort_by(|a, b| b.0.total_cmp(&a.0));
            scored
        };

        let mut out: Vec<Candidate> = Vec::with_capacity(picked.len().min(MAX_RESULTS));
        for (score, i) in picked {
            let e = &all[i];
            // 同一个符号可能出现在多个组里，只保留分最高的那次
            if out.iter().any(|c| c.text == e.glyph) {
                continue;
            }
            out.push(
                Candidate::new(e.glyph, consumed, CandidateKind::Symbol, score)
                    .with_comment(e.label),
            );
            if out.len() >= MAX_RESULTS {
                break;
            }
        }
        out
    }
}

impl Decoder for SymbolDecoder {
    fn decode(&self, input: &str) -> Vec<Candidate> {
        self.decode_buffer(input)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trigger_alone_shows_featured_across_groups() {
        let c = SymbolDecoder.decode_buffer("u");
        assert_eq!(c.len(), FEATURED_COUNT);
        assert!(c.iter().all(|x| x.consumed == 1));
        assert!(c.iter().all(|x| x.kind == CandidateKind::Symbol));
        // 精选应跨组，不是某一组刷屏
        assert!(c.iter().any(|x| x.text == "…"), "{c:?}");
        assert!(c.iter().any(|x| x.text == "±"), "{c:?}");
        assert!(c.iter().any(|x| x.text == "￥"), "{c:?}");
    }

    #[test]
    fn exact_alias_wins() {
        let c = SymbolDecoder.candidates("duihao");
        assert_eq!(c[0].text, "✓", "{c:?}");
        assert_eq!(c[0].comment.as_deref(), Some("对号"));

        let c = SymbolDecoder.candidates("sheshidu");
        assert_eq!(c[0].text, "℃", "{c:?}");
    }

    #[test]
    fn group_alias_recalls_whole_group() {
        let c = SymbolDecoder.candidates("jiantou");
        assert!(c.len() >= 10, "整组箭头应被召回: {c:?}");
        assert!(c.iter().any(|x| x.text == "→"));
        assert!(c.iter().any(|x| x.text == "⇔"));
    }

    #[test]
    fn english_alias_also_matches() {
        let c = SymbolDecoder.candidates("euro");
        assert_eq!(c[0].text, "€", "{c:?}");
        let c = SymbolDecoder.candidates("alpha");
        assert_eq!(c[0].text, "α", "{c:?}");
    }

    #[test]
    fn buffer_must_start_with_trigger() {
        assert!(SymbolDecoder.decode_buffer("nihao").is_empty());
        let c = SymbolDecoder.decode_buffer("ujiantou");
        assert!(!c.is_empty());
        assert!(c.iter().all(|x| x.consumed == 8), "consumed 应含触发键");
    }

    #[test]
    fn unknown_query_is_empty() {
        assert!(SymbolDecoder.candidates("zzzzzz").is_empty());
    }

    #[test]
    fn results_are_deduped() {
        let c = SymbolDecoder.candidates("xing");
        let mut texts: Vec<_> = c.iter().map(|x| x.text.clone()).collect();
        texts.sort();
        let before = texts.len();
        texts.dedup();
        assert_eq!(before, texts.len(), "同一符号不应重复出现: {c:?}");
    }
}
