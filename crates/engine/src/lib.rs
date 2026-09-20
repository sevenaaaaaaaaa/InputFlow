//! 会话编排：持有输入缓冲、组合态与用户词模型，是平台前端唯一需要打交道的对象。

use std::sync::Arc;

use inputflow_core::{Composition, Decoder, Mode, UserModel};
use inputflow_dict::Dictionary;
use inputflow_en::EnDecoder;
use inputflow_ja::JaDecoder;
use inputflow_pinyin::{Layout, PinyinDecoder};

/// 单次组合态最多返回的候选数（前端分页展示）。
pub const MAX_CANDIDATES: usize = 30;

pub struct Session {
    mode: Mode,
    buffer: String,
    comp: Composition,
    dict: Arc<Dictionary>,
    en: EnDecoder,
    ja: JaDecoder,
    user: UserModel,
}

impl Session {
    pub fn new(dict: Arc<Dictionary>) -> Self {
        Self::with_mode(dict, Mode::Pinyin)
    }

    pub fn with_mode(dict: Arc<Dictionary>, mode: Mode) -> Self {
        Self {
            mode,
            buffer: String::new(),
            comp: Composition::default(),
            dict,
            en: EnDecoder::embedded(),
            ja: JaDecoder,
            user: UserModel::new(),
        }
    }

    pub fn mode(&self) -> Mode {
        self.mode
    }

    pub fn buffer(&self) -> &str {
        &self.buffer
    }

    pub fn composition(&self) -> &Composition {
        &self.comp
    }

    pub fn user_model(&self) -> &UserModel {
        &self.user
    }

    pub fn user_model_mut(&mut self) -> &mut UserModel {
        &mut self.user
    }

    /// 前端按键入口。只接受字母与 `'`、`;`（微软双拼 ing 键）。
    pub fn feed(&mut self, ch: char) -> bool {
        let ok = ch.is_ascii_alphabetic() || ch == '\'' || ch == ';';
        if !ok {
            return false;
        }
        match self.mode {
            Mode::English => self.buffer.push(ch),
            _ => self.buffer.push(ch.to_ascii_lowercase()),
        }
        self.refresh();
        true
    }

    pub fn backspace(&mut self) -> bool {
        if self.buffer.pop().is_some() {
            self.refresh();
            true
        } else {
            false
        }
    }

    pub fn clear(&mut self) {
        self.buffer.clear();
        self.comp = Composition::default();
    }

    pub fn set_mode(&mut self, mode: Mode) {
        if self.mode != mode {
            self.mode = mode;
            self.clear();
        }
    }

    /// 选择候选词上屏；返回提交文本，剩余缓冲继续解码。
    pub fn select(&mut self, index: usize) -> Option<String> {
        let cand = self.comp.candidates.get(index)?.clone();
        self.consume(cand.consumed);
        self.user.record(&cand.text);
        Some(cand.text)
    }

    /// 原样上屏当前缓冲。
    pub fn commit_raw(&mut self) -> Option<String> {
        if self.buffer.is_empty() {
            return None;
        }
        let s = std::mem::take(&mut self.buffer);
        self.refresh();
        Some(s)
    }

    fn consume(&mut self, n: usize) {
        let mut chars = self.buffer.chars();
        for _ in 0..n {
            if chars.next().is_none() {
                break;
            }
        }
        self.buffer = chars.as_str().to_string();
        while self.buffer.starts_with('\'') {
            self.buffer.remove(0);
        }
        self.refresh();
    }

    fn refresh(&mut self) {
        if self.buffer.is_empty() {
            self.comp = Composition::default();
            return;
        }
        let (mut cands, preedit) = match self.mode {
            Mode::Pinyin => {
                let d = PinyinDecoder::new(self.dict.clone(), Layout::Full);
                (d.candidates(&self.buffer), d.preedit(&self.buffer))
            }
            Mode::Shuangpin(s) => {
                let d = PinyinDecoder::new(self.dict.clone(), Layout::Shuangpin(s));
                (d.candidates(&self.buffer), d.preedit(&self.buffer))
            }
            Mode::English => (self.en.decode(&self.buffer), self.buffer.clone()),
            Mode::Japanese => {
                let preedit =
                    inputflow_ja::to_hiragana(&self.buffer).unwrap_or_else(|| self.buffer.clone());
                (self.ja.decode(&self.buffer), preedit)
            }
        };
        for c in &mut cands {
            c.score += self.user.bonus(&c.text);
        }
        cands.sort_by(|a, b| b.score.total_cmp(&a.score));
        cands.truncate(MAX_CANDIDATES);
        self.comp = Composition {
            raw: self.buffer.clone(),
            preedit,
            candidates: cands,
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(mode: Mode) -> Session {
        Session::with_mode(Arc::new(Dictionary::embedded()), mode)
    }

    fn type_str(s: &mut Session, text: &str) {
        for ch in text.chars() {
            s.feed(ch);
        }
    }

    #[test]
    fn pinyin_type_and_commit() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "nihao");
        assert_eq!(s.composition().raw, "nihao");
        assert_eq!(s.composition().preedit, "ni hao");
        assert_eq!(s.composition().candidates[0].text, "你好");
        assert_eq!(s.select(0).as_deref(), Some("你好"));
        assert!(s.buffer().is_empty());
        assert!(s.composition().is_empty());
    }

    #[test]
    fn select_keeps_remaining_buffer() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "ni");
        let c = s
            .composition()
            .candidates
            .iter()
            .position(|c| c.text == "你")
            .expect("应有「你」");
        assert_eq!(s.select(c).as_deref(), Some("你"));
        assert!(s.buffer().is_empty());

        type_str(&mut s, "nihao");
        let idx = s
            .composition()
            .candidates
            .iter()
            .position(|c| c.text == "你" && c.consumed == 2)
            .expect("应有消费 2 字符的「你」");
        assert_eq!(s.select(idx).as_deref(), Some("你"));
        assert_eq!(s.buffer(), "hao");
        assert_eq!(s.composition().candidates[0].text, "好");
    }

    #[test]
    fn backspace_and_clear() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "ni");
        assert!(s.backspace());
        assert_eq!(s.buffer(), "n");
        assert!(s.backspace());
        assert!(!s.backspace());
        type_str(&mut s, "hao");
        s.clear();
        assert!(s.composition().is_empty());
    }

    #[test]
    fn ignores_non_letter_keys() {
        let mut s = session(Mode::Pinyin);
        assert!(!s.feed(' '));
        assert!(!s.feed('1'));
        assert!(s.feed('n'));
        assert!(s.feed('\''));
        assert!(s.feed(';'));
    }

    #[test]
    fn commit_raw_returns_typed_text() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "zzz");
        assert_eq!(s.commit_raw().as_deref(), Some("zzz"));
        assert!(s.commit_raw().is_none());
    }

    #[test]
    fn shuangpin_modes_work() {
        let mut s = session(Mode::Shuangpin(inputflow_core::Scheme::Flypy));
        type_str(&mut s, "nihc");
        assert_eq!(s.composition().candidates[0].text, "你好");
        assert_eq!(s.composition().preedit, "ni hao");

        s.set_mode(Mode::Shuangpin(inputflow_core::Scheme::Mspy));
        type_str(&mut s, "hk");
        assert!(s.composition().candidates.iter().any(|c| c.text == "好"));
    }

    #[test]
    fn english_mode_keeps_case() {
        let mut s = session(Mode::English);
        type_str(&mut s, "Hel");
        assert_eq!(s.composition().candidates[0].text, "Hello");
    }

    #[test]
    fn japanese_mode_previews_kana() {
        let mut s = session(Mode::Japanese);
        type_str(&mut s, "nihon");
        assert_eq!(s.composition().preedit, "にほん");
        assert_eq!(s.composition().candidates[0].text, "にほん");
    }

    #[test]
    fn user_model_reranks_after_repeated_selection() {
        let mut s = session(Mode::Pinyin);
        s.clear();
        type_str(&mut s, "shi");
        assert_ne!(s.composition().candidates[0].text, "时", "初始不应是「时」");
        for _ in 0..12 {
            s.clear();
            type_str(&mut s, "shi");
            let idx = s
                .composition()
                .candidates
                .iter()
                .position(|c| c.text == "时")
                .expect("应有「时」");
            s.select(idx);
        }
        s.clear();
        type_str(&mut s, "shi");
        assert_eq!(
            s.composition().candidates[0].text,
            "时",
            "重复选择后应被重排到首位（当前首位: {}）",
            s.composition().candidates[0].text
        );
    }

    #[test]
    fn switching_mode_clears_buffer() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "ni");
        s.set_mode(Mode::English);
        assert!(s.buffer().is_empty());
        assert_eq!(s.mode(), Mode::English);
    }
}
