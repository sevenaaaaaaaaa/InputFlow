//! 表情模式：常用表情 + 拼音关键词过滤。零依赖、纯本地。
//!
//! 触发方式由前端决定（例如聊天应用里连按两下 `a`），本 crate 只负责：
//! 空输入展示精选表情，输入拼音关键词时按别名过滤。

use std::sync::OnceLock;

use inputflow_core::{Candidate, CandidateKind, Decoder};

mod data;

pub use data::EMOJI;

/// 空输入时展示的精选数量。
pub const FEATURED_COUNT: usize = 40;

/// 别名索引：`(alias, emoji_index)`，按别名排序便于前缀匹配。
fn alias_index() -> &'static [(String, usize)] {
    static INDEX: OnceLock<Vec<(String, usize)>> = OnceLock::new();
    INDEX.get_or_init(|| {
        let mut v = Vec::with_capacity(EMOJI.len() * 3);
        for (i, (_, aliases, _)) in EMOJI.iter().enumerate() {
            for alias in aliases.split_whitespace() {
                v.push((alias.to_string(), i));
            }
        }
        v.sort();
        v
    })
}

pub struct EmojiDecoder;

impl EmojiDecoder {
    pub fn candidates(&self, input: &str) -> Vec<Candidate> {
        let query = input.trim().to_ascii_lowercase();
        if query.is_empty() {
            return EMOJI
                .iter()
                .take(FEATURED_COUNT)
                .map(|(glyph, _, label)| {
                    Candidate::new(*glyph, 0, CandidateKind::Emoji, 0.0).with_comment(*label)
                })
                .collect();
        }

        let index = alias_index();
        let start = index.partition_point(|(a, _)| a.as_str() < query.as_str());
        let mut scored: Vec<(f64, usize)> = Vec::new();
        for (alias, emoji_idx) in &index[start..] {
            if !alias.starts_with(&query) {
                break;
            }
            let exact = alias.len() == query.len();
            let score = if exact { 3.0 } else { 2.0 } - (*emoji_idx as f64) * 1e-4;
            scored.push((score, *emoji_idx));
        }
        // 别名中段包含（例如 `xiao` 命中 `daxiao`）作为次级结果
        for (i, (_, aliases, _)) in EMOJI.iter().enumerate() {
            if scored.iter().any(|(_, idx)| *idx == i) {
                continue;
            }
            if aliases
                .split_whitespace()
                .any(|a| a.len() > query.len() && a.contains(&query))
            {
                scored.push((1.0 - (i as f64) * 1e-4, i));
            }
        }

        scored.sort_by(|a, b| b.0.total_cmp(&a.0));
        scored.dedup_by_key(|(_, i)| *i);
        scored
            .into_iter()
            .take(30)
            .map(|(score, i)| {
                let (glyph, _, label) = EMOJI[i];
                Candidate::new(glyph, query.chars().count(), CandidateKind::Emoji, score)
                    .with_comment(label)
            })
            .collect()
    }
}

impl Decoder for EmojiDecoder {
    fn decode(&self, input: &str) -> Vec<Candidate> {
        self.candidates(input)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_input_shows_featured() {
        let d = EmojiDecoder;
        let c = d.candidates("");
        assert_eq!(c.len(), FEATURED_COUNT);
        assert_eq!(c[0].text, "😀");
        assert!(c.iter().all(|x| x.kind == CandidateKind::Emoji));
    }

    #[test]
    fn pinyin_filters_by_alias() {
        let d = EmojiDecoder;
        let c = d.candidates("daku");
        assert_eq!(c[0].text, "😭", "{c:?}");
        assert_eq!(c[0].comment.as_deref(), Some("大哭"));

        let c = d.candidates("zan");
        assert_eq!(c[0].text, "👍");

        let c = d.candidates("gou");
        assert_eq!(c[0].text, "🐶");
    }

    #[test]
    fn prefix_and_contains_match() {
        let d = EmojiDecoder;
        let c = d.candidates("ku");
        assert!(c.iter().any(|x| x.text == "😂"), "{c:?}");
        assert!(c.iter().any(|x| x.text == "😭"), "{c:?}");

        let c = d.candidates("xiao");
        assert!(c.len() > 1, "{c:?}");
    }

    #[test]
    fn no_match_is_empty() {
        let d = EmojiDecoder;
        assert!(d.candidates("zzzz").is_empty());
    }
}
