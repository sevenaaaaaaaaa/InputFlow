//! 词典：内存索引 + IFD1 二进制格式 + 导入器。零第三方依赖。

pub mod binary;
pub mod import;

use std::collections::HashMap;
use std::fmt;

pub use import::{ImportReport, normalize_pinyin};

/// 词条。`letters`/`syls` 由 key 推导，用于计算候选消费掉多少按键字符。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub word: String,
    pub freq: u32,
    pub letters: u16,
    pub syls: u16,
}

#[derive(Debug, Default)]
pub struct Dictionary {
    map: HashMap<String, Vec<Entry>>,
    entries: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DictError {
    BadMagic,
    Truncated,
    Overflow,
    InvalidUtf8,
}

impl fmt::Display for DictError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            DictError::BadMagic => "不是合法的 IFD1 词典文件",
            DictError::Truncated => "词典文件被截断",
            DictError::Overflow => "词典文件长度字段溢出",
            DictError::InvalidUtf8 => "词典文件包含非法 UTF-8",
        };
        f.write_str(s)
    }
}

impl std::error::Error for DictError {}

const EMPTY: &[Entry] = &[];

impl Dictionary {
    pub fn new() -> Self {
        Self::default()
    }

    /// 插入或提升词频。key 形如 `ni'hao`。
    pub fn insert(&mut self, key: &str, word: &str, freq: u32) {
        if key.is_empty() || word.is_empty() {
            return;
        }
        let letters = key.bytes().filter(u8::is_ascii_alphabetic).count() as u16;
        let syls = key.split('\'').count() as u16;
        let freq = freq.max(1);
        let list = self.map.entry(key.to_string()).or_default();
        if let Some(e) = list.iter_mut().find(|e| e.word == word) {
            if freq > e.freq {
                e.freq = freq;
            }
        } else {
            list.push(Entry {
                word: word.to_string(),
                freq,
                letters,
                syls,
            });
            self.entries += 1;
        }
        if list.len() > 1 {
            list.sort_by(|a, b| b.freq.cmp(&a.freq).then_with(|| a.word.cmp(&b.word)));
        }
    }

    /// 按 key 查候选（词频降序，同频按字典序）。
    pub fn lookup(&self, key: &str) -> &[Entry] {
        self.map.get(key).map(Vec::as_slice).unwrap_or(EMPTY)
    }

    pub fn contains_key(&self, key: &str) -> bool {
        self.map.contains_key(key)
    }

    pub fn key_count(&self) -> usize {
        self.map.len()
    }

    pub fn entry_count(&self) -> usize {
        self.entries
    }

    pub fn is_empty(&self) -> bool {
        self.entries == 0
    }

    /// 合并另一个词典（同 key 同词取较大词频）。
    pub fn merge(&mut self, other: &Dictionary) {
        for (key, list) in &other.map {
            for e in list {
                self.insert(key, &e.word, e.freq);
            }
        }
    }

    /// 确定性序列化（key 排序后写入），便于校验与 diff。
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut keys: Vec<&String> = self.map.keys().collect();
        keys.sort();
        let mut out = Vec::with_capacity(64 + self.entries * 12);
        out.extend_from_slice(&binary::MAGIC);
        binary::write_varint(&mut out, self.entries as u64);
        for key in keys {
            for e in &self.map[key] {
                binary::write_str(&mut out, key);
                binary::write_str(&mut out, &e.word);
                binary::write_varint(&mut out, u64::from(e.freq));
            }
        }
        out
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self, DictError> {
        if bytes.len() < 4 || bytes[..4] != binary::MAGIC {
            return Err(DictError::BadMagic);
        }
        let mut pos = 4;
        let count = binary::read_varint(bytes, &mut pos)? as usize;
        let mut dict = Dictionary::new();
        for _ in 0..count {
            let key = binary::read_str(bytes, &mut pos)?;
            let word = binary::read_str(bytes, &mut pos)?;
            let freq = binary::read_varint(bytes, &mut pos)? as u32;
            dict.insert(&key, &word, freq);
        }
        Ok(dict)
    }

    /// 内置基础词典（约 200 条），保证首次可用与测试确定性。
    /// 正式词库用 `xtask dict import-rime` 从 Rime 词库生成。
    pub fn embedded() -> Self {
        import::parse_tsv(include_str!("../data/base.tsv")).0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn demo() -> Dictionary {
        let mut d = Dictionary::new();
        d.insert("ni'hao", "你好", 100);
        d.insert("ni'hao", "泥号", 1);
        d.insert("ni", "你", 500);
        d
    }

    #[test]
    fn lookup_order_and_dedupe() {
        let d = demo();
        let l = d.lookup("ni'hao");
        assert_eq!(l.len(), 2);
        assert_eq!(l[0].word, "你好");
        assert_eq!(l[0].letters, 5);
        assert_eq!(l[0].syls, 2);
        assert_eq!(l[1].word, "泥号");
        assert!(d.lookup("nothing").is_empty());
    }

    #[test]
    fn duplicate_word_keeps_max_freq() {
        let mut d = Dictionary::new();
        d.insert("ni", "你", 1);
        d.insert("ni", "你", 9);
        assert_eq!(d.entry_count(), 1);
        assert_eq!(d.lookup("ni")[0].freq, 9);
    }

    #[test]
    fn binary_roundtrip_is_deterministic() {
        let d = demo();
        let b1 = d.to_bytes();
        let b2 = d.to_bytes();
        assert_eq!(b1, b2);
        let r = Dictionary::from_bytes(&b1).unwrap();
        assert_eq!(r.entry_count(), d.entry_count());
        assert_eq!(r.to_bytes(), b1);
        assert_eq!(r.lookup("ni'hao")[0].word, "你好");
    }

    #[test]
    fn binary_rejects_garbage() {
        assert_eq!(
            Dictionary::from_bytes(b"NOPE").unwrap_err(),
            DictError::BadMagic
        );
        assert_eq!(
            Dictionary::from_bytes(b"IFD1").unwrap_err(),
            DictError::Truncated
        );
    }

    #[test]
    fn merge_keeps_max() {
        let mut a = Dictionary::new();
        a.insert("ni", "你", 5);
        let mut b = Dictionary::new();
        b.insert("ni", "你", 7);
        b.insert("ni", "尼", 3);
        a.merge(&b);
        assert_eq!(a.entry_count(), 2);
        assert_eq!(a.lookup("ni")[0].freq, 7);
    }

    #[test]
    fn embedded_dict_is_clean_and_useful() {
        let (d, report) = import::parse_tsv(include_str!("../data/base.tsv"));
        assert_eq!(report.skipped, 0, "内置词典有非法行: {:?}", report.errors);
        assert!(report.imported > 150);
        assert_eq!(d.lookup("ni'hao")[0].word, "你好");
        assert!(!d.lookup("wo'men").is_empty());
    }
}
