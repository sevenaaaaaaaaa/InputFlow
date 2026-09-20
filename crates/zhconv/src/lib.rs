//! 简繁转换（简 → 繁）：OpenCC 词表离线内置，零依赖、纯函数。
//!
//! 只做「简 → 繁」一个方向。输入法里用户打的是拼音、候选天然是简体，
//! 「繁」开关要做的只是把候选转成繁体显示；反向转换没有使用场景。
//!
//! 一对多的简体字（发 → 發/髮、干 → 幹/乾/干）靠**最长匹配**消歧：
//! 先查词组表（`头发` → `頭髮`），查不到才退回单字表（`发` → `發`）。
//! 词表允许恒等映射（OpenCC 用它做分词），解析时直接丢弃以省内存。

use std::collections::HashMap;
use std::sync::OnceLock;

/// 单字表：简体字 → 繁体字。
const CHARS: &str = include_str!("../data/STCharacters.txt");
/// 词组表：简体词 → 繁体词，用于消歧。
const PHRASES: &str = include_str!("../data/STPhrases.txt");

/// 参与匹配的最长条目字符数。词表里更长的条目（谚语、整句）对输入法没意义，
/// 且会让每个字符多做十几次哈希查询，直接丢弃。
const MAX_KEY_CHARS: usize = 8;

/// 低于此码位的字符不可能出现在简体词表里，直接跳过匹配（ASCII / 常用标点）。
const CJK_START: char = '\u{2e80}';

struct Table {
    map: HashMap<&'static str, &'static str>,
    max_chars: usize,
}

fn table() -> &'static Table {
    static TABLE: OnceLock<Table> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut map = HashMap::with_capacity(48 * 1024);
        let mut max_chars = 1;
        // 词组优先：同一个键同时出现在两张表时，以词组表为准。
        parse_into(PHRASES, &mut map, &mut max_chars);
        parse_into(CHARS, &mut map, &mut max_chars);
        Table { map, max_chars }
    })
}

/// 解析 OpenCC 词表：`键\t值1 值2 ...`，只取第一个（最常用的）值。
fn parse_into(
    src: &'static str,
    map: &mut HashMap<&'static str, &'static str>,
    max_chars: &mut usize,
) {
    for line in src.lines() {
        let line = line.trim_end();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut it = line.splitn(2, '\t');
        let (Some(key), Some(values)) = (it.next(), it.next()) else {
            continue;
        };
        let Some(value) = values.split_whitespace().next() else {
            continue;
        };
        // 恒等映射是 OpenCC 的分词用条目，对我们没有价值。
        if key.is_empty() || value.is_empty() || key == value {
            continue;
        }
        let n = key.chars().count();
        if n > MAX_KEY_CHARS {
            continue;
        }
        if map.insert(key, value).is_none() {
            *max_chars = (*max_chars).max(n);
        }
    }
}

/// 简体 → 繁体。非中文字符原样保留；输入不含简体字时返回等价副本。
pub fn s2t(text: &str) -> String {
    if text.is_empty() {
        return String::new();
    }
    let t = table();
    let bounds: Vec<usize> = text
        .char_indices()
        .map(|(i, _)| i)
        .chain(std::iter::once(text.len()))
        .collect();
    let n = bounds.len() - 1;
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < n {
        let head = text[bounds[i]..bounds[i + 1]].chars().next().unwrap_or(' ');
        if head < CJK_START {
            out.push(head);
            i += 1;
            continue;
        }
        let max = t.max_chars.min(n - i);
        let mut matched = 0;
        for len in (1..=max).rev() {
            let slice = &text[bounds[i]..bounds[i + len]];
            if let Some(v) = t.map.get(slice) {
                out.push_str(v);
                matched = len;
                break;
            }
        }
        if matched == 0 {
            out.push(head);
            i += 1;
        } else {
            i += matched;
        }
    }
    out
}

/// 转换后是否与原文不同（前端据此决定要不要标注「繁」）。
pub fn differs(text: &str) -> bool {
    s2t(text) != text
}

/// 词表条目数（测试与诊断用）。
pub fn entry_count() -> usize {
    table().map.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_chars_convert() {
        assert_eq!(s2t("简体"), "簡體");
        assert_eq!(s2t("国际"), "國際");
        assert_eq!(s2t("学习"), "學習");
    }

    #[test]
    fn phrases_disambiguate_one_to_many() {
        // 发：頭髮 vs 發現；干：乾淨 vs 幹活；里：裏面 vs 公里
        assert_eq!(s2t("头发"), "頭髮");
        assert_eq!(s2t("发现"), "發現");
        assert_eq!(s2t("干净"), "乾淨");
        assert_eq!(s2t("里面"), "裏面");
    }

    #[test]
    fn non_chinese_passes_through() {
        assert_eq!(s2t(""), "");
        assert_eq!(s2t("hello, world! 123"), "hello, world! 123");
        assert_eq!(s2t("😀"), "😀");
        assert_eq!(s2t("学习 Rust 2026"), "學習 Rust 2026");
    }

    #[test]
    fn already_traditional_is_stable() {
        let t = s2t("簡體");
        assert_eq!(s2t(&t), t, "繁体再转一次应保持不变");
    }

    #[test]
    fn differs_flags_only_real_changes() {
        assert!(differs("简体"));
        assert!(!differs("hello"));
        assert!(!differs("天上"));
    }

    #[test]
    fn table_is_loaded() {
        assert!(entry_count() > 10_000, "词表条目数: {}", entry_count());
    }
}
