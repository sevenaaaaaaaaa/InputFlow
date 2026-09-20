//! 会话编排：持有输入缓冲、组合态与用户词模型，是平台前端唯一需要打交道的对象。

use std::sync::Arc;

use inputflow_core::backup::{self, BackupError};
use inputflow_core::{Composition, Decoder, Mode, UserModel};
use inputflow_dict::Dictionary;
use inputflow_emoji::EmojiDecoder;
use inputflow_en::EnDecoder;
use inputflow_ja::JaDecoder;
use inputflow_pinyin::{Layout, PinyinDecoder};
use inputflow_symbol::SymbolDecoder;

/// 单次组合态最多返回的候选数（前端分页展示）。
pub const MAX_CANDIDATES: usize = 30;
/// 中英混输时最多掺入的英文候选数。
const MAX_MIXED_ENGLISH: usize = 5;
/// 中英混输里「精确英文词」判定的最短长度（避免 `he`/`can` 这类拼音噪声）。
const MIN_EXACT_ENGLISH: usize = 4;

// ——— AI 辅助短语（不做手动短语表，全部自动学习）———
/// 参与合并的最近上屏段数：窗口内的所有后缀组合都会被记一次。
const PHRASE_WINDOW: usize = 3;
/// 短语的按键序列上限，超出不再学（太长的句子复用率低）。
const MAX_PHRASE_KEYS: usize = 14;
/// 短语的字数上限。
const MAX_PHRASE_CHARS: usize = 8;
/// 触发短语补全的最短按键数。
const MIN_PHRASE_QUERY: usize = 3;
/// 按键完全命中时的最低学习次数。
const MIN_PHRASE_EXACT: u32 = 2;
/// 按键只是前缀（补全）时的最低学习次数——门槛更高，避免打一半就被抢。
const MIN_PHRASE_PREFIX: u32 = 3;
/// 短语候选的基础分（对齐整句候选的量级，见 `inputflow_pinyin` 的打分）。
const PHRASE_SCORE_EXACT: f64 = 18.0;
const PHRASE_SCORE_PREFIX: f64 = 12.0;

pub struct Session {
    mode: Mode,
    buffer: String,
    comp: Composition,
    dict: Arc<Dictionary>,
    en: Arc<EnDecoder>,
    ja: JaDecoder,
    emoji: EmojiDecoder,
    symbol: SymbolDecoder,
    user: UserModel,
    /// 上一个上屏内容，用于二元组预测（只在内存、进程退出即消失）。
    last_committed: Option<String>,
    /// 最近几段上屏的 `(按键, 文本)`，用于自动合成短语。
    recent: Vec<(String, String)>,
    /// 候选是否转成繁体显示（学习与重排始终用简体原文）。
    traditional: bool,
    /// 与 `comp.candidates` 同下标的简体原文，仅在繁体显示时非空。
    origins: Vec<String>,
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
            symbol: SymbolDecoder,
            user: UserModel::new(),
            last_committed: None,
            recent: Vec::new(),
            traditional: false,
            origins: Vec::new(),
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
        self.recent.clear();
    }

    pub fn mode(&self) -> Mode {
        self.mode
    }

    /// 候选是否以繁体呈现。
    pub fn traditional(&self) -> bool {
        self.traditional
    }

    /// 切换简/繁显示。只影响呈现与上屏文本，用户词与重排仍以简体为准。
    pub fn set_traditional(&mut self, on: bool) {
        if self.traditional != on {
            self.traditional = on;
            self.refresh();
        }
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

    /// 导出用户数据备份包（带版本头与 CRC32，见 `inputflow_core::backup`）。
    ///
    /// 包内是明文 TSV：写盘时由前端用本机密钥加密，导出明文须用户二次确认。
    pub fn export_backup(&self) -> String {
        let body = self.user.export_tsv();
        let items = body.lines().filter(|l| !l.is_empty()).count();
        backup::pack(backup::KIND_USERDATA, items, &body)
    }

    /// 导入备份包。`merge` 为真时同名条目取较大次数（重复导入不翻倍），
    /// 否则以备份为准覆盖。校验失败时**不改动**任何现有数据。
    pub fn import_backup(&mut self, text: &str, merge: bool) -> Result<usize, BackupError> {
        let b = backup::unpack(text)?;
        if b.kind != backup::KIND_USERDATA {
            return Err(BackupError::NotBackup);
        }
        let n = if merge {
            self.user.merge_tsv(&b.body)
        } else {
            self.user.import_tsv(&b.body)
        };
        Ok(n)
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
        let keys: String = self.buffer.chars().take(cand.consumed).collect();
        // 学习始终记简体原文：繁体只是呈现层，换回简体显示时重排仍然生效。
        let learned = self
            .origins
            .get(index)
            .cloned()
            .unwrap_or_else(|| cand.text.clone());
        self.consume(cand.consumed);
        if self.mode != Mode::Emoji {
            self.user.record(&learned);
            // 短语要用「上一段」的按键，必须排在 learn_context 之前
            self.learn_phrase(&keys, &learned);
            self.learn_context(&learned);
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

    /// 自动学习短语：把最近几段上屏与本次拼接，窗口内的每个后缀组合各记一次。
    ///
    /// 这就是「AI 辅助短语」——没有手动短语表，用户重复打出来的搭配自己沉淀下来。
    fn learn_phrase(&mut self, keys: &str, text: &str) {
        if !matches!(self.mode, Mode::Pinyin | Mode::Shuangpin(_)) {
            self.recent.clear();
            return;
        }
        let keys: String = keys
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .map(|c| c.to_ascii_lowercase())
            .collect();
        // 英文、符号、表情不进短语库：它们不是「打出来的词」。
        if keys.is_empty() || !text.chars().all(is_phrase_char) {
            self.recent.clear();
            return;
        }
        for start in (0..self.recent.len()).rev() {
            let mut k = String::new();
            let mut t = String::new();
            for (pk, pt) in &self.recent[start..] {
                k.push_str(pk);
                t.push_str(pt);
            }
            k.push_str(&keys);
            t.push_str(text);
            if k.chars().count() <= MAX_PHRASE_KEYS && t.chars().count() <= MAX_PHRASE_CHARS {
                self.user.record_phrase(&k, &t);
            }
        }
        self.recent.push((keys, text.to_string()));
        if self.recent.len() > PHRASE_WINDOW {
            self.recent.remove(0);
        }
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
        self.origins.clear();
        if self.buffer.is_empty() && self.mode != Mode::Emoji {
            self.comp = Composition::default();
            return;
        }
        // `u` 前缀进符号模式：普通话没有以 u 开头的音节，不会和拼音抢输入。
        let symbol_hit =
            if self.mode == Mode::Pinyin && self.buffer.starts_with(inputflow_symbol::TRIGGER) {
                let c = self.symbol.decode_buffer(&self.buffer);
                (!c.is_empty()).then_some(c)
            } else {
                None
            };
        if let Some(cands) = symbol_hit {
            self.finish(cands, self.buffer.clone());
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
                self.push_phrase_candidates(&mut cands);
                self.push_english_candidates(&mut cands);
            }
        }
        self.finish(cands, preedit);
    }

    /// 候选收尾：分层排序 → 截断 → 简繁转换 → 落到组合态。
    fn finish(&mut self, mut cands: Vec<inputflow_core::Candidate>, preedit: String) {
        // 分层排序：literal 垫底、覆盖输入多的优先，用户词只在同层内重排。
        cands.sort_by(inputflow_core::Candidate::rank_cmp);
        cands.truncate(MAX_CANDIDATES);
        if self.traditional {
            self.origins.clear();
            self.origins.reserve(cands.len());
            for c in &mut cands {
                let converted = inputflow_zhconv::s2t(&c.text);
                if converted == c.text {
                    self.origins.push(c.text.clone());
                } else {
                    self.origins.push(std::mem::replace(&mut c.text, converted));
                }
            }
        }
        self.comp = Composition {
            raw: self.buffer.clone(),
            preedit,
            candidates: cands,
        };
    }

    /// 短语补全：把学到的短语按当前按键前缀召回。
    ///
    /// 按键完全命中（学过 2 次）时按整句量级给分；只是前缀（学过 3 次）时给较低分，
    /// 让它出现在前几位但不抢正常整句的首位。
    fn push_phrase_candidates(&self, cands: &mut Vec<inputflow_core::Candidate>) {
        use inputflow_core::{Candidate, CandidateKind};
        let raw: String = self
            .buffer
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .map(|c| c.to_ascii_lowercase())
            .collect();
        let consumed = self.buffer.chars().count();
        if raw.chars().count() < MIN_PHRASE_QUERY {
            return;
        }
        for (keys, text, count) in self.user.phrase_matches(&raw, 5) {
            let exact = keys.len() == raw.len();
            let min = if exact {
                MIN_PHRASE_EXACT
            } else {
                MIN_PHRASE_PREFIX
            };
            if count < min {
                continue;
            }
            let score = if exact {
                PHRASE_SCORE_EXACT
            } else {
                PHRASE_SCORE_PREFIX
            } + (count as f64).ln();
            // 解码器已经给出同样的词时只提分，不塞重复候选
            if let Some(existing) = cands
                .iter_mut()
                .find(|c| c.text == text && c.consumed == consumed)
            {
                existing.score = existing.score.max(score);
                continue;
            }
            cands.push(
                Candidate::new(text, consumed, CandidateKind::Phrase, score).with_comment("短语"),
            );
        }
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

/// 能进短语库的字符：中日韩文字。英文、数字、符号、表情都排除在外。
fn is_phrase_char(c: char) -> bool {
    matches!(c, '\u{3400}'..='\u{9fff}' | '\u{f900}'..='\u{faff}')
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
    fn traditional_converts_candidates_but_learns_simplified() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "xuexi");
        let simplified = s.composition().candidates[0].text.clone();
        assert_eq!(simplified, "学习");
        s.clear();

        s.set_traditional(true);
        assert!(s.traditional());
        type_str(&mut s, "xuexi");
        assert_eq!(s.composition().candidates[0].text, "學習");
        assert_eq!(s.select(0).as_deref(), Some("學習"));
        assert_eq!(s.user_model().count("学习"), 1, "学习应记在简体词条上");
        assert_eq!(s.user_model().count("學習"), 0);

        // 关掉开关后回到简体，之前的学习仍然生效
        s.set_traditional(false);
        type_str(&mut s, "xuexi");
        assert_eq!(s.composition().candidates[0].text, "学习");
    }

    #[test]
    fn traditional_keeps_english_and_emoji_untouched() {
        let mut s = session(Mode::Pinyin);
        s.set_traditional(true);
        type_str(&mut s, "hello");
        assert_eq!(s.composition().candidates[0].text, "hello");

        s.set_mode(Mode::Emoji);
        type_str(&mut s, "daku");
        assert_eq!(s.composition().candidates[0].text, "😭");
    }

    #[test]
    fn symbol_mode_triggers_on_u_prefix() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "u");
        let c = &s.composition().candidates;
        assert!(!c.is_empty());
        assert!(
            c.iter()
                .all(|x| x.kind == inputflow_core::CandidateKind::Symbol),
            "{c:?}"
        );

        s.clear();
        type_str(&mut s, "uduihao");
        assert_eq!(s.composition().candidates[0].text, "✓");
        assert_eq!(s.select(0).as_deref(), Some("✓"));
        assert!(s.buffer().is_empty(), "符号上屏后应吃掉整个缓冲");
    }

    #[test]
    fn symbol_prefix_falls_back_to_pinyin_when_no_match() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "uzzzz");
        let c = &s.composition().candidates;
        assert!(
            c.iter()
                .all(|x| x.kind != inputflow_core::CandidateKind::Symbol),
            "无命中应退回普通管线: {c:?}"
        );
        assert!(!c.is_empty());
    }

    #[test]
    fn symbol_prefix_does_not_break_normal_pinyin() {
        let mut s = session(Mode::Pinyin);
        // wu / nu 等以 u 结尾或含 u 的音节不受影响
        type_str(&mut s, "wu");
        assert!(
            s.composition()
                .candidates
                .iter()
                .any(|c| c.kind == inputflow_core::CandidateKind::Char
                    || c.kind == inputflow_core::CandidateKind::Word),
            "{:?}",
            s.composition().candidates
        );
    }

    #[test]
    fn phrase_is_learned_from_consecutive_commits() {
        let mut s = session(Mode::Pinyin);
        let sequence = [("beijing", "北京"), ("shijie", "世界")];
        for _ in 0..2 {
            s.reset_context();
            for (keys, text) in sequence {
                type_str(&mut s, keys);
                let idx = s
                    .composition()
                    .candidates
                    .iter()
                    .position(|c| c.text == text)
                    .unwrap_or_else(|| panic!("应有「{text}」"));
                s.select(idx);
            }
        }
        assert_eq!(
            s.user_model().phrase_count("beijingshijie", "北京世界"),
            2,
            "连续上屏应沉淀成短语"
        );

        // 窗口是最近 3 段：第三段进来后，两段与三段组合都要记上
        s.reset_context();
        for (keys, text) in [("nihao", "你好"), ("beijing", "北京"), ("shijie", "世界")] {
            type_str(&mut s, keys);
            let idx = s
                .composition()
                .candidates
                .iter()
                .position(|c| c.text == text)
                .unwrap_or_else(|| panic!("应有「{text}」"));
            s.select(idx);
        }
        assert_eq!(s.user_model().phrase_count("nihaobeijing", "你好北京"), 1);
        assert_eq!(
            s.user_model()
                .phrase_count("nihaobeijingshijie", "你好北京世界"),
            0,
            "超过字数/按键上限的组合不学"
        );
    }

    #[test]
    fn learned_phrase_completes_on_prefix() {
        let mut s = session(Mode::Pinyin);
        // 手工灌入一个学过 4 次的短语，避免依赖具体词库候选
        for _ in 0..4 {
            s.user_model_mut().record_phrase("zaoshanghao", "早上好");
        }
        type_str(&mut s, "zaosh");
        let c = &s.composition().candidates;
        let hit = c
            .iter()
            .find(|x| x.text == "早上好")
            .expect("前缀应补全出短语");
        assert_eq!(hit.kind, inputflow_core::CandidateKind::Phrase);
        assert_eq!(hit.comment.as_deref(), Some("短语"));
        assert_eq!(hit.consumed, 5, "短语候选吃掉当前全部按键");
    }

    #[test]
    fn rare_phrase_does_not_surface() {
        let mut s = session(Mode::Pinyin);
        s.user_model_mut().record_phrase("zaoshanghao", "早上好");
        type_str(&mut s, "zaosh");
        assert!(
            !s.composition()
                .candidates
                .iter()
                .any(|x| x.kind == inputflow_core::CandidateKind::Phrase),
            "只学过一次不应冒出来: {:?}",
            s.composition().candidates
        );
    }

    #[test]
    fn english_and_symbol_commits_do_not_pollute_phrases() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "hello");
        s.select(0);
        type_str(&mut s, "uduihao");
        s.select(0);
        type_str(&mut s, "nihao");
        let idx = s
            .composition()
            .candidates
            .iter()
            .position(|c| c.text == "你好")
            .expect("应有「你好」");
        s.select(idx);
        assert_eq!(s.user_model().phrase_len(), 0, "非中文上屏不该进短语库");
    }

    #[test]
    fn backup_roundtrip_and_rejects_damaged_package() {
        let mut s = session(Mode::Pinyin);
        type_str(&mut s, "nihao");
        s.select(0);
        s.user_model_mut().record_phrase("nihaoshijie", "你好世界");
        let pack = s.export_backup();
        assert!(pack.contains("#kind: userdata"), "{pack}");

        let mut fresh = session(Mode::Pinyin);
        let n = fresh.import_backup(&pack, false).expect("应能导入");
        assert!(n >= 2, "导入条目数: {n}");
        assert_eq!(fresh.user_model().count("你好"), 1);
        assert_eq!(
            fresh.user_model().phrase_count("nihaoshijie", "你好世界"),
            1
        );

        // 重复合并不翻倍
        fresh.import_backup(&pack, true).unwrap();
        assert_eq!(fresh.user_model().count("你好"), 1);

        // 损坏的包一律拒绝，且不动现有数据
        let broken = pack.replace("你好\t1", "你好\t999");
        assert!(fresh.import_backup(&broken, false).is_err());
        assert!(fresh.import_backup("随便一段文本", false).is_err());
        assert_eq!(fresh.user_model().count("你好"), 1);
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
