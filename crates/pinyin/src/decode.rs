use std::collections::HashSet;
use std::sync::Arc;

use inputflow_core::syllables::{is_syllable, is_syllable_prefix};
use inputflow_core::{Candidate, CandidateKind, Scheme};
use inputflow_dict::Dictionary;

use crate::scheme::{Codes, MAX_SYLLABLE_LEN};

/// 一条词边最多覆盖的音节数。
pub const MAX_WORD_SYLLABLES: usize = 6;
/// 切分路径上限（防止长串在歧义处指数爆炸）。
pub const MAX_PATHS: usize = 64;
/// 单次解码允许的最大输入字符数。
pub const MAX_INPUT_CHARS: usize = 64;
/// 尾部无法成音节的残余最多按这么长当作未输完的尾巴保留。
const MAX_GARBAGE_TAIL: usize = 3;
/// 整句切分时每个「词」的惩罚（≈ ln 语料规模），使 N 个单字不敌一个常用词。
const WORD_PENALTY: f64 = 17.0;
/// 完全无法成词时的旁路惩罚（保留原样音节）。
const PASS_THROUGH_PENALTY: f64 = -40.0;
/// 候选排序中每个音节的长度加成（覆盖输入越多越靠前）。
const LEN_BONUS: f64 = 1.8;
/// 选择最佳切分时每个输入字符的覆盖加成（避免用更短的切分胜出）。
const COVERAGE_BONUS: f64 = 1.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Layout {
    Full,
    Shuangpin(Scheme),
}

impl Layout {
    pub fn is_shuangpin(&self) -> bool {
        matches!(self, Layout::Shuangpin(_))
    }
}

/// 音节段。`syl == None` 表示尾部未输完的部分（不参与解码，提交时保留）。
#[derive(Clone, Debug)]
struct Seg {
    syl: Option<String>,
    /// 归一化字符序列中的区间终点（起点即上一段的终点）
    end: usize,
}

#[derive(Clone, Debug, Default)]
struct Hyp {
    /// 切分打分（含词惩罚，用于选择最佳切分）
    score: f64,
    /// 不加惩罚的 ln 频率之和（用于与词候选同尺度排序）
    sum_ln: f64,
    /// 由真实词典词覆盖的音节数（旁路音节不计入长度加成）
    matched: usize,
    text: String,
    pinyin: Vec<String>,
}

pub struct PinyinDecoder {
    dict: Arc<Dictionary>,
    layout: Layout,
    codes: Codes,
}

impl PinyinDecoder {
    pub fn new(dict: Arc<Dictionary>, layout: Layout) -> Self {
        let codes = match layout {
            Layout::Shuangpin(s) => Codes::build(s),
            Layout::Full => Codes::default(),
        };
        Self {
            dict,
            layout,
            codes,
        }
    }

    pub fn layout(&self) -> Layout {
        self.layout
    }

    pub fn candidates(&self, input: &str) -> Vec<Candidate> {
        let (chars, orig) = normalize(input);
        if chars.is_empty() {
            return Vec::new();
        }
        let limit = chars.len().min(MAX_INPUT_CHARS);
        let chars = &chars[..limit];
        let orig = &orig[..limit];
        let raw: String = input
            .chars()
            .filter(|c| c.is_ascii_alphabetic() || *c == ';')
            .collect();

        let paths = self.segment(chars);
        let mut out: Vec<Candidate> = Vec::new();
        let mut best: Option<(Hyp, usize, usize)> = None;
        for path in &paths {
            self.decode_path(orig, path, &mut out);
            let usable: Vec<&Seg> = path.iter().take_while(|s| s.syl.is_some()).collect();
            if usable.is_empty() {
                continue;
            }
            if let Some(h) = self.viterbi(&usable) {
                let consumed = orig[usable.last().expect("非空").end - 1] + 1;
                let cover = (
                    h.score + COVERAGE_BONUS * consumed as f64,
                    consumed,
                    usable.len(),
                );
                let better = best.as_ref().is_none_or(|(cur, cur_consumed, _)| {
                    cover.0 > cur.score + COVERAGE_BONUS * *cur_consumed as f64
                });
                if better {
                    best = Some((h, consumed, usable.len()));
                }
            }
        }
        if let Some((hyp, consumed, syls)) = best {
            let kind = if syls == 1 {
                CandidateKind::Char
            } else {
                CandidateKind::Sentence
            };
            let score = hyp.sum_ln + LEN_BONUS * hyp.matched as f64 + 1.0;
            let mut c = Candidate::new(hyp.text, consumed, kind, score);
            if !hyp.pinyin.is_empty() {
                c = c.with_comment(hyp.pinyin.join(" "));
            }
            out.push(c);
        }
        out.push(Candidate::new(
            raw,
            chars.len(),
            CandidateKind::Literal,
            -1000.0,
        ));
        dedupe_and_sort(&mut out);
        out.truncate(30);
        out
    }

    /// 预编辑串（按当前切分显示，未输完的尾巴原样保留）。
    pub fn preedit(&self, input: &str) -> String {
        let (chars, _) = normalize(input);
        match self.layout {
            Layout::Full => greedy_full(&chars),
            Layout::Shuangpin(_) => {
                let mut s = chunk_decode(&chars, &self.codes);
                if chars.len() > MAX_INPUT_CHARS {
                    s.truncate(s.len());
                }
                s
            }
        }
    }

    /// 生成切分路径。双拼模式下同时保留「整串按全拼解释」的路径（宽容输入）。
    fn segment(&self, chars: &[char]) -> Vec<Vec<Seg>> {
        let mut paths = match self.layout {
            Layout::Shuangpin(_) => segment_shuangpin(chars, &self.codes),
            Layout::Full => Vec::new(),
        };
        for p in segment_full(chars) {
            if paths.len() >= MAX_PATHS {
                break;
            }
            let sig: Vec<&str> = p.iter().map(|s| s.syl.as_deref().unwrap_or("")).collect();
            let dup = paths.iter().any(|q| {
                q.len() == p.len()
                    && q.iter()
                        .zip(sig.iter())
                        .all(|(a, b)| a.syl.as_deref().unwrap_or("") == *b)
            });
            if !dup {
                paths.push(p);
            }
        }
        paths.truncate(MAX_PATHS);
        paths
    }

    fn decode_path(&self, orig: &[usize], path: &[Seg], out: &mut Vec<Candidate>) {
        let usable: Vec<&Seg> = path.iter().take_while(|s| s.syl.is_some()).collect();
        if usable.is_empty() {
            return;
        }

        // 覆盖输入前缀的词候选
        let mut key = String::new();
        for k in 1..=usable.len().min(MAX_WORD_SYLLABLES) {
            if k > 1 {
                key.push('\'');
            }
            key.push_str(usable[k - 1].syl.as_deref().unwrap_or_default());
            let consumed = orig[usable[k - 1].end - 1] + 1;
            let display = key.replace('\'', " ");
            for e in self.dict.lookup(&key) {
                let kind = if e.syls <= 1 {
                    CandidateKind::Char
                } else {
                    CandidateKind::Word
                };
                let score = (e.freq as f64).ln() + LEN_BONUS * f64::from(e.syls);
                out.push(
                    Candidate::new(e.word.clone(), consumed, kind, score)
                        .with_comment(display.clone()),
                );
            }
        }
    }

    /// Viterbi：按「词惩罚」选择最佳切分，返回唯一最佳假设。
    fn viterbi(&self, segs: &[&Seg]) -> Option<Hyp> {
        let n = segs.len();
        let mut dp: Vec<Option<Hyp>> = vec![None; n + 1];
        dp[0] = Some(Hyp::default());
        for i in 0..n {
            let Some(base) = dp[i].clone() else { continue };
            for k in 1..=MAX_WORD_SYLLABLES.min(n - i) {
                let mut key = String::new();
                for (j, s) in segs[i..i + k].iter().enumerate() {
                    if j > 0 {
                        key.push('\'');
                    }
                    key.push_str(s.syl.as_deref().unwrap_or_default());
                }
                let entries = self.dict.lookup(&key);
                let (text, wscore, sum_ln, matched, pys) = if entries.is_empty() {
                    if k == 1 {
                        let raw = segs[i].syl.clone().unwrap_or_default();
                        (raw.clone(), PASS_THROUGH_PENALTY, 0.0, 0, vec![raw])
                    } else {
                        continue;
                    }
                } else {
                    let e = &entries[0];
                    let ln = (e.freq as f64).ln();
                    (
                        e.word.clone(),
                        ln - WORD_PENALTY,
                        ln,
                        k,
                        key.split('\'').map(str::to_string).collect::<Vec<_>>(),
                    )
                };
                let mut pinyin = base.pinyin.clone();
                pinyin.extend(pys);
                let cand = Hyp {
                    score: base.score + wscore,
                    sum_ln: base.sum_ln + sum_ln,
                    matched: base.matched + matched,
                    text: format!("{}{}", base.text, text),
                    pinyin,
                };
                let better = dp[i + k].as_ref().is_none_or(|cur| cand.score > cur.score);
                if better {
                    dp[i + k] = Some(cand);
                }
            }
        }
        dp[n].clone()
    }
}

fn dedupe_and_sort(out: &mut Vec<Candidate>) {
    out.sort_by(|a, b| b.score.total_cmp(&a.score));
    let mut seen: HashSet<(String, usize)> = HashSet::new();
    out.retain(|c| seen.insert((c.text.clone(), c.consumed)));
}

/// 归一化输入：只保留小写字母与 `;`（微软 ing 键），返回字符序列与「归一化 → 原始」索引。
pub fn normalize(input: &str) -> (Vec<char>, Vec<usize>) {
    let mut chars = Vec::new();
    let mut orig = Vec::new();
    for (i, c) in input.chars().enumerate() {
        if c.is_ascii_alphabetic() {
            chars.push(c.to_ascii_lowercase());
            orig.push(i);
        } else if c == ';' {
            chars.push(';');
            orig.push(i);
        }
    }
    (chars, orig)
}

fn segment_full(chars: &[char]) -> Vec<Vec<Seg>> {
    let mut out: Vec<Vec<Seg>> = Vec::new();
    let mut cur: Vec<Seg> = Vec::new();
    go_full(0, chars, &mut cur, &mut out);
    fn go_full(i: usize, chars: &[char], cur: &mut Vec<Seg>, out: &mut Vec<Vec<Seg>>) {
        let n = chars.len();
        if out.len() >= MAX_PATHS {
            return;
        }
        if i == n {
            out.push(cur.clone());
            return;
        }
        for len in 1..=MAX_SYLLABLE_LEN.min(n - i) {
            let s: String = chars[i..i + len].iter().collect();
            if is_syllable(&s) {
                cur.push(Seg {
                    syl: Some(s),
                    end: i + len,
                });
                go_full(i + len, chars, cur, out);
                cur.pop();
                if out.len() >= MAX_PATHS {
                    return;
                }
            }
        }
        let rest: String = chars[i..].iter().collect();
        if !is_syllable(&rest) && (is_syllable_prefix(&rest) || rest.len() <= MAX_GARBAGE_TAIL) {
            cur.push(Seg { syl: None, end: n });
            out.push(cur.clone());
            cur.pop();
        }
    }
    out
}

fn segment_shuangpin(chars: &[char], codes: &Codes) -> Vec<Vec<Seg>> {
    let mut out: Vec<Vec<Seg>> = Vec::new();
    let mut cur: Vec<Seg> = Vec::new();
    go_sp(0, chars, codes, &mut cur, &mut out);
    fn go_sp(i: usize, chars: &[char], codes: &Codes, cur: &mut Vec<Seg>, out: &mut Vec<Vec<Seg>>) {
        let n = chars.len();
        if out.len() >= MAX_PATHS {
            return;
        }
        if i == n {
            out.push(cur.clone());
            return;
        }
        if i + 2 <= n {
            let code: String = chars[i..i + 2].iter().collect();
            for syl in codes.syllables(&code).to_vec() {
                cur.push(Seg {
                    syl: Some(syl.to_string()),
                    end: i + 2,
                });
                go_sp(i + 2, chars, codes, cur, out);
                cur.pop();
                if out.len() >= MAX_PATHS {
                    return;
                }
            }
        }
        if n - i == 1 {
            cur.push(Seg { syl: None, end: n });
            out.push(cur.clone());
            cur.pop();
        }
    }
    out
}

fn greedy_full(chars: &[char]) -> String {
    let mut parts: Vec<String> = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let mut matched = None;
        for len in (1..=MAX_SYLLABLE_LEN.min(chars.len() - i)).rev() {
            let s: String = chars[i..i + len].iter().collect();
            if is_syllable(&s) {
                matched = Some((s, len));
                break;
            }
        }
        match matched {
            Some((s, len)) => {
                parts.push(s);
                i += len;
            }
            None => {
                parts.push(chars[i].to_string());
                i += 1;
            }
        }
    }
    parts.join(" ")
}

fn chunk_decode(chars: &[char], codes: &Codes) -> String {
    let mut parts: Vec<String> = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if i + 2 <= chars.len() {
            let code: String = chars[i..i + 2].iter().collect();
            let syls = codes.syllables(&code);
            if let Some(first) = syls.first() {
                parts.push((*first).to_string());
                i += 2;
                continue;
            }
        }
        parts.push(chars[i].to_string());
        i += 1;
    }
    parts.join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dict() -> Arc<Dictionary> {
        Arc::new(Dictionary::embedded())
    }

    fn first(decode: &PinyinDecoder, input: &str) -> String {
        decode.candidates(input)[0].text.clone()
    }

    #[test]
    fn full_pinyin_common_words() {
        let d = PinyinDecoder::new(dict(), Layout::Full);
        assert_eq!(first(&d, "nihao"), "你好");
        assert_eq!(first(&d, "beijing"), "北京");
        assert_eq!(first(&d, "shurufa"), "输入法");
        assert_eq!(first(&d, "zhongguo"), "中国");
        assert_eq!(first(&d, "woshi"), "我是");
    }

    #[test]
    fn consumed_counts_chars() {
        let d = PinyinDecoder::new(dict(), Layout::Full);
        assert_eq!(d.candidates("nihao")[0].consumed, 5);
        let c = d
            .candidates("nihaoma")
            .into_iter()
            .find(|c| c.text == "你")
            .expect("应包含「你」");
        assert_eq!(c.consumed, 2);
    }

    #[test]
    fn trailing_partial_is_not_consumed() {
        let d = PinyinDecoder::new(dict(), Layout::Full);
        let cands = d.candidates("nihm");
        assert!(
            cands
                .iter()
                .filter(|c| c.kind != CandidateKind::Literal)
                .all(|c| c.consumed <= 2),
            "{cands:?}"
        );
        assert!(cands.iter().any(|c| c.text == "你"));
        assert_eq!(d.preedit("nihm"), "ni h m");
    }

    #[test]
    fn literal_fallback_always_present() {
        let d = PinyinDecoder::new(dict(), Layout::Full);
        let cands = d.candidates("zzz");
        assert_eq!(cands.len(), 1);
        assert_eq!(cands[0].text, "zzz");
        assert_eq!(cands[0].kind, CandidateKind::Literal);
        assert_eq!(cands[0].consumed, 3);
    }

    #[test]
    fn shuangpin_flypy_types_words() {
        let d = PinyinDecoder::new(dict(), Layout::Shuangpin(Scheme::Flypy));
        assert_eq!(first(&d, "nihc"), "你好");
        assert_eq!(first(&d, "vsgo"), "中国");
        assert_eq!(first(&d, "uurufa"), "输入法");
        assert_eq!(first(&d, "aj"), "安");
        assert_eq!(d.preedit("nihc"), "ni hao");
    }

    #[test]
    fn shuangpin_falls_back_to_full_spelling() {
        let d = PinyinDecoder::new(dict(), Layout::Shuangpin(Scheme::Flypy));
        assert_eq!(first(&d, "nihao"), "你好");
    }

    #[test]
    fn input_longer_than_cap_is_bounded() {
        let d = PinyinDecoder::new(dict(), Layout::Full);
        let long = "ni".repeat(80);
        let cands = d.candidates(&long);
        assert!(!cands.is_empty());
    }

    #[test]
    fn apostrophe_is_ignored_for_decoding_but_counted() {
        let d = PinyinDecoder::new(dict(), Layout::Full);
        let c = d
            .candidates("xi'an")
            .into_iter()
            .find(|c| c.text == "西安")
            .expect("应包含「西安」");
        assert_eq!(c.consumed, 5, "含撇号在内的消费数应为 5");
    }
}
