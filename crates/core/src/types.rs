use std::cmp::Ordering;
use std::fmt;

/// 双拼方案。解码端对各方案的差异持宽容态度（见 `inputflow-pinyin::scheme`）。
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Scheme {
    Flypy,
    Mspy,
    Zrm,
}

impl Scheme {
    pub const ALL: [Scheme; 3] = [Scheme::Flypy, Scheme::Mspy, Scheme::Zrm];

    pub fn id(self) -> &'static str {
        match self {
            Scheme::Flypy => "flypy",
            Scheme::Mspy => "mspy",
            Scheme::Zrm => "zrm",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Scheme::Flypy => "小鹤双拼",
            Scheme::Mspy => "微软双拼",
            Scheme::Zrm => "自然码",
        }
    }

    pub fn from_id(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|x| x.id() == s)
    }
}

/// 输入模式。`Pinyin` 为全拼，其余复用同一套解码管线。
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Mode {
    Pinyin,
    Shuangpin(Scheme),
    English,
    Japanese,
    /// 表情模式（由前端手势临时进入，不出现在常规模式菜单里）。
    Emoji,
}

impl Mode {
    pub const ALL: [Mode; 7] = [
        Mode::Pinyin,
        Mode::Shuangpin(Scheme::Flypy),
        Mode::Shuangpin(Scheme::Mspy),
        Mode::Shuangpin(Scheme::Zrm),
        Mode::English,
        Mode::Japanese,
        Mode::Emoji,
    ];

    pub fn id(self) -> &'static str {
        match self {
            Mode::Pinyin => "pinyin",
            Mode::Shuangpin(s) => s.id(),
            Mode::English => "en",
            Mode::Japanese => "ja",
            Mode::Emoji => "emoji",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Mode::Pinyin => "拼音",
            Mode::Shuangpin(s) => s.label(),
            Mode::English => "English",
            Mode::Japanese => "日本語",
            Mode::Emoji => "表情",
        }
    }

    pub fn from_id(s: &str) -> Option<Self> {
        if s == "pinyin" {
            return Some(Mode::Pinyin);
        }
        if s == "en" {
            return Some(Mode::English);
        }
        if s == "ja" {
            return Some(Mode::Japanese);
        }
        if s == "emoji" {
            return Some(Mode::Emoji);
        }
        Scheme::from_id(s).map(Mode::Shuangpin)
    }

    /// 是否接受 ASCII 字母作为输入（中文与英文）；日语为罗马字。
    pub fn accepts_letters(self) -> bool {
        true
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum CandidateKind {
    /// 整句（覆盖全部可解码输入）
    Sentence,
    Word,
    Char,
    Kana,
    /// 表情符号
    Emoji,
    /// 原样上屏
    Literal,
}

impl CandidateKind {
    pub fn id(self) -> &'static str {
        match self {
            CandidateKind::Sentence => "sentence",
            CandidateKind::Word => "word",
            CandidateKind::Char => "char",
            CandidateKind::Kana => "kana",
            CandidateKind::Emoji => "emoji",
            CandidateKind::Literal => "literal",
        }
    }
}

/// 候选词。`consumed` 表示选中后应从前端预编辑串中消费的**字符数**（非字节）。
#[derive(Clone, Debug)]
pub struct Candidate {
    pub text: String,
    pub consumed: usize,
    pub kind: CandidateKind,
    pub comment: Option<String>,
    pub score: f64,
}

impl Candidate {
    pub fn new(text: impl Into<String>, consumed: usize, kind: CandidateKind, score: f64) -> Self {
        Self {
            text: text.into(),
            consumed,
            kind,
            comment: None,
            score,
        }
    }

    pub fn with_comment(mut self, comment: impl Into<String>) -> Self {
        self.comment = Some(comment.into());
        self
    }

    /// 候选排序：literal 垫底；覆盖输入多的在前；同层按分数降序。
    ///
    /// 所有前端排序都必须走这个函数，保证用户词重排不会打乱分层。
    pub fn rank_cmp(&self, other: &Self) -> Ordering {
        let literal = (self.kind == CandidateKind::Literal) as u8;
        let other_literal = (other.kind == CandidateKind::Literal) as u8;
        literal
            .cmp(&other_literal)
            .then_with(|| other.consumed.cmp(&self.consumed))
            .then_with(|| other.score.total_cmp(&self.score))
    }
}

impl fmt::Display for Candidate {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}({})", self.text, self.consumed)
    }
}

/// 组合态：前端据此渲染预编辑串与候选列表。
#[derive(Clone, Debug, Default)]
pub struct Composition {
    /// 原始按键串
    pub raw: String,
    /// 解码后的显示串（全拼按音节空格分隔）
    pub preedit: String,
    pub candidates: Vec<Candidate>,
}

impl Composition {
    pub fn is_empty(&self) -> bool {
        self.raw.is_empty()
    }
}

/// 各模式解码器契约。解码必须是纯函数：同输入必得同输出。
pub trait Decoder: Send + Sync {
    fn decode(&self, input: &str) -> Vec<Candidate>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mode_roundtrip() {
        for m in Mode::ALL {
            assert_eq!(Mode::from_id(m.id()), Some(m));
        }
        assert_eq!(Mode::from_id("nope"), None);
    }

    #[test]
    fn candidate_consumed_is_chars() {
        let c = Candidate::new("你好", 5, CandidateKind::Word, 1.0);
        assert_eq!(c.consumed, 5);
        assert_eq!(c.kind, CandidateKind::Word);
    }
}
