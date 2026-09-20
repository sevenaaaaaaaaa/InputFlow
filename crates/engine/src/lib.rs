//! 会话编排：持有输入缓冲、组合态与用户词模型，是平台前端唯一需要打交道的对象。

use std::sync::Arc;

use inputflow_core::{Composition, Decoder, Mode, UserModel};
use inputflow_dict::Dictionary;
use inputflow_emoji::EmojiDecoder;
use inputflow_en::EnDecoder;
use inputflow_ja::JaDecoder;
use inputflow_pinyin::{Layout, PinyinDecoder};

/// 单次组合态最多返回的候选数（前端分页展示）。
pub const MAX_CANDIDATES: usize = 30;
/// 中英混输时最多掺入的英文候选数。
const MAX_MIXED_ENGLISH: usize = 5;
/// 中英混输里「精确英文词」判定的最短长度（避免 `he`/`can` 这类拼音噪声）。
const MIN_EXACT_ENGLISH: usize = 4;

pub struct Session {
    mode: Mode,
    buffer: String,
    comp: Composition,
    dict: Arc<Dictionary>,
    en: Arc<EnDecoder>,
    ja: JaDecoder,
    emoji: EmojiDecoder,
    user: UserModel,
    /// 上一个上屏内容，用于二元组预测（只在内存、进程退出即消失）。
    last_committed: Option<String>,
}

impl Session {
    pub fn new(dict: Arc<Dictionary>) -> Self {
        Self::with_mode(dict, Mode::Pinyin)
    }

    pub fn with_mode(dict: Arc<Dictionary>, mode: Mode) -> Self {
        let mut session = Self {
            mode,
            buffer: String::new(),
            comp: Composition::default(),
            dict,
            en: EnDecoder::embedded_shared(),
            ja: JaDecoder,
            emoji: EmojiDecoder,
            user: UserModel::new(),
            last_committed: None,
        };
        session.refresh();
        session
    }

    /// 上一个上屏内容（候选预测上下文）。
    pub fn last_committed(&self) -> Option<&str> {
        self.last_committed.as_deref()
    }

    /// 清空预测上下文（例如前端切换焦点、退出输入状态时调用）。
    pub fn reset_context(&mut self) {
        self.last_committed = None;
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
            // 中文模式保留大小写：大写是「英文意图」信号，继续由解码器小写归一化
            Mode::Pinyin | Mode::Shuangpin(_) | Mode::English => self.buffer.push(ch),
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
        if self.mode != Mode::Emoji {
            self.user.record(&cand.text);
            self.learn_context(&cand.text);
        }
        Some(cand.text)
    }

    /// 原样上屏当前缓冲。
    pub fn commit_raw(&mut self) -> Option<String> {
        if self.buffer.is_empty() {
            return None;
        }
        let s = std::mem::take(&mut self.buffer);
        self.learn_context(&s);
        self.refresh();
        Some(s)
    }

    fn learn_context(&mut self, text: &str) {
        if let Some(prev) = self.last_committed.take() {
            self.user.record_pair(&prev, text);
        }
        self.last_committed = Some(text.to_string());
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
        if self.buffer.is_empty() && self.mode != Mode::Emoji {
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
            Mode::Emoji => (self.emoji.decode(&self.buffer), self.buffer.clone()),
        };
        if self.mode != Mode::Emoji {
            for c in &mut cands {
                c.score += self.user.bonus(&c.text);
                if let Some(prev) = &self.last_committed {
                    c.score += self.user.pair_bonus(prev, &c.text);
                }
            }
            if matches!(self.mode, Mode::Pinyin | Mode::Shuangpin(_)) {
                self.push_english_candidates(&mut cands);
            }
        }
        // 分层排序：literal 垫底、覆盖输入多的优先，用户词只在同层内重排。
        cands.sort_by(inputflow_core::Candidate::rank_cmp);
        cands.truncate(MAX_CANDIDATES);
        self.comp = Composition {
            raw: self.buffer.clone(),
            preedit,
            candidates: cands,
        };
    }

    /// 中英混输：中文模式里掺入英文候选。
    ///
    /// 触发条件：输入无法完整解成中文（有残余）、或本身是长度 ≥4 的英文词、
    /// 或用户按了 Shift（大写意图）。短词（如 `he`）不触发，避免拼音噪声。
    fn push_english_candidates(&self, cands: &mut Vec<inputflow_core::Candidate>) {
        use inputflow_core::CandidateKind;
        let raw = self.buffer.as_str();
        let has_real_zh = cands.iter().any(|c| c.kind != CandidateKind::Literal);
        let lower = raw.to_ascii_lowercase();
        let upper_intent = raw.chars().any(|c| c.is_ascii_uppercase());
        let exact_word = lower.chars().count() >= MIN_EXACT_ENGLISH && self.en.contains(&lower);
        if has_real_zh && !exact_word && !upper_intent {
            return;
        }
        let consumed = raw.chars().count();
        for mut c in self
            .en
            .decode_for_mix(raw)
            .into_iter()
            .take(MAX_MIXED_ENGLISH)
        {
            c.consumed = consumed;
            // 高于 literal（-1000），但不抢中文整句的层级。
            c.score = c.score.max(-100.0);
            cands.push(c);
        }
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
    fn candidates_keep_coverage_tiers() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "nihao");
        let c = &s.composition().candidates;
        let zh: Vec<_> = c
            .iter()
            .filter(|x| x.kind != inputflow_core::CandidateKind::Literal)
            .collect();
        let first_partial = zh.iter().position(|x| x.consumed < 5).unwrap_or(zh.len());
        assert!(first_partial > 0, "应有覆盖全部输入的候选");
        assert!(
            zh[..first_partial].iter().all(|x| x.consumed == 5),
            "覆盖全部的候选必须排在最前: {:?}",
            zh.iter().map(|x| (&x.text, x.consumed)).collect::<Vec<_>>()
        );
        assert!(
            zh[first_partial..].iter().all(|x| x.consumed < 5),
            "部分覆盖的候选不能插队: {:?}",
            zh.iter().map(|x| (&x.text, x.consumed)).collect::<Vec<_>>()
        );
        assert_eq!(
            c.last().map(|x| x.kind),
            Some(inputflow_core::CandidateKind::Literal),
            "原样上屏永远垫底"
        );
    }

    #[test]
    fn bigram_context_boosts_next_word() {
        let mut s = session(Mode::Pinyin);

        // 训练「北京 → 世界」：两次上屏形成二元组
        for _ in 0..3 {
            type_str(&mut s, "beijing");
            let idx = s
                .composition()
                .candidates
                .iter()
                .position(|c| c.text == "北京")
                .expect("应有「北京」");
            s.select(idx);
            type_str(&mut s, "shijie");
            let idx = s
                .composition()
                .candidates
                .iter()
                .position(|c| c.text == "世界")
                .expect("应有「世界」");
            s.select(idx);
        }
        assert!(s.user_model().pair_count("北京", "世界") > 0);

        // 上下文是「北京」时，世界应得到加分
        type_str(&mut s, "beijing");
        let idx = s
            .composition()
            .candidates
            .iter()
            .position(|c| c.text == "北京")
            .expect("应有「北京」");
        s.select(idx);
        assert_eq!(s.last_committed(), Some("北京"));
        type_str(&mut s, "shijie");
        let with_ctx = s
            .composition()
            .candidates
            .iter()
            .find(|c| c.text == "世界")
            .expect("应有「世界」")
            .score;

        // 上下文换成别的词后，同一候选分数应更低
        s.reset_context();
        s.clear();
        type_str(&mut s, "nihao");
        s.select(0);
        type_str(&mut s, "shijie");
        let without_ctx = s
            .composition()
            .candidates
            .iter()
            .find(|c| c.text == "世界")
            .expect("应有「世界」")
            .score;
        assert!(
            with_ctx > without_ctx,
            "有上下文 {with_ctx} 应高于无上下文 {without_ctx}"
        );
    }

    #[test]
    fn mixed_input_completes_english_word() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "hello");
        let c = &s.composition().candidates;
        assert_eq!(c[0].text, "hello", "{c:?}");
        assert_eq!(c[0].consumed, 5);
        assert_eq!(s.select(0).as_deref(), Some("hello"));
    }

    #[test]
    fn mixed_input_keeps_case_intent() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "Hello");
        let c = &s.composition().candidates;
        assert_eq!(c[0].text, "Hello", "{c:?}");
    }

    #[test]
    fn mixed_input_does_not_noise_short_pinyin() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "he");
        let c = &s.composition().candidates;
        assert_ne!(c[0].text, "he", "短拼音不应被英文词抢占: {c:?}");
        assert_eq!(s.composition().preedit, "he");
    }

    #[test]
    fn mixed_input_exact_long_word_beats_partial_chinese() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "test");
        let c = &s.composition().candidates;
        assert_eq!(c[0].text, "test", "{c:?}");
    }

    #[test]
    fn emoji_mode_featured_and_filter() {
        let mut s = session(Mode::Emoji);
        let c = &s.composition().candidates;
        assert!(!c.is_empty());
        assert_eq!(c[0].text, "😀");

        type_str(&mut s, "daku");
        let c = &s.composition().candidates;
        assert_eq!(c[0].text, "😭", "{c:?}");
        assert_eq!(s.select(0).as_deref(), Some("😭"));
        assert!(s.buffer().is_empty());
        assert_eq!(s.user_model().count("😭"), 0, "表情不进用户词库");
    }

    #[test]
    fn english_mode_keeps_case() {
        let mut s = session(Mode::English);
        type_str(&mut s, "Hel");
        assert_eq!(s.composition().candidates[0].text, "Help");
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
