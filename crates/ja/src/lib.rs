//! 日语输入（阶段一）：罗马字 → 平假名 / 片假名。
//!
//! 采用「最长匹配 + 促音/拨音规则」的确定性转换；假名→汉字的 Viterbi 转换在 M2
//! （JMdict + 连接矩阵），届时复用 `inputflow-dict` 与 `inputflow-pinyin` 的 DP 思路。

use inputflow_core::{Candidate, CandidateKind, Decoder};

/// 罗马字表（按长度做最长匹配；含拗音、外来语音节与常用简写）。
const TABLE: &[(&str, &str)] = &[
    // 母音
    ("a", "あ"),
    ("i", "い"),
    ("u", "う"),
    ("e", "え"),
    ("o", "お"),
    // か行
    ("ka", "か"),
    ("ki", "き"),
    ("ku", "く"),
    ("ke", "け"),
    ("ko", "こ"),
    ("kya", "きゃ"),
    ("kyu", "きゅ"),
    ("kyo", "きょ"),
    // さ行
    ("sa", "さ"),
    ("shi", "し"),
    ("si", "し"),
    ("su", "す"),
    ("se", "せ"),
    ("so", "そ"),
    ("sha", "しゃ"),
    ("shu", "しゅ"),
    ("sho", "しょ"),
    ("sya", "しゃ"),
    ("syu", "しゅ"),
    ("syo", "しょ"),
    // た行
    ("ta", "た"),
    ("chi", "ち"),
    ("ti", "ち"),
    ("tsu", "つ"),
    ("tu", "つ"),
    ("te", "て"),
    ("to", "と"),
    ("cha", "ちゃ"),
    ("chu", "ちゅ"),
    ("cho", "ちょ"),
    ("cya", "ちゃ"),
    ("cyu", "ちゅ"),
    ("cyo", "ちょ"),
    ("tha", "てゃ"),
    ("thi", "てぃ"),
    ("thu", "てゅ"),
    ("the", "てぇ"),
    ("tho", "てょ"),
    // な行
    ("na", "な"),
    ("ni", "に"),
    ("nu", "ぬ"),
    ("ne", "ね"),
    ("no", "の"),
    ("nya", "にゃ"),
    ("nyu", "にゅ"),
    ("nyo", "にょ"),
    // は行
    ("ha", "は"),
    ("hi", "ひ"),
    ("fu", "ふ"),
    ("hu", "ふ"),
    ("he", "へ"),
    ("ho", "ほ"),
    ("hya", "ひゃ"),
    ("hyu", "ひゅ"),
    ("hyo", "ひょ"),
    ("fa", "ふぁ"),
    ("fi", "ふぃ"),
    ("fe", "ふぇ"),
    ("fo", "ふぉ"),
    ("fyu", "ふゅ"),
    // ま行
    ("ma", "ま"),
    ("mi", "み"),
    ("mu", "む"),
    ("me", "め"),
    ("mo", "も"),
    ("mya", "みゃ"),
    ("myu", "みゅ"),
    ("myo", "みょ"),
    // や行
    ("ya", "や"),
    ("yu", "ゆ"),
    ("yo", "よ"),
    // ら行
    ("ra", "ら"),
    ("ri", "り"),
    ("ru", "る"),
    ("re", "れ"),
    ("ro", "ろ"),
    ("rya", "りゃ"),
    ("ryu", "りゅ"),
    ("ryo", "りょ"),
    // わ行・ん
    ("wa", "わ"),
    ("wi", "うぃ"),
    ("we", "うぇ"),
    ("wo", "を"),
    ("nn", "ん"),
    ("n", "ん"),
    // が行
    ("ga", "が"),
    ("gi", "ぎ"),
    ("gu", "ぐ"),
    ("ge", "げ"),
    ("go", "ご"),
    ("gya", "ぎゃ"),
    ("gyu", "ぎゅ"),
    ("gyo", "ぎょ"),
    // ざ行
    ("za", "ざ"),
    ("ji", "じ"),
    ("zi", "じ"),
    ("zu", "ず"),
    ("ze", "ぜ"),
    ("zo", "ぞ"),
    ("ja", "じゃ"),
    ("ju", "じゅ"),
    ("jo", "じょ"),
    ("zya", "じゃ"),
    ("zyu", "じゅ"),
    ("zyo", "じょ"),
    // だ行
    ("da", "だ"),
    ("di", "ぢ"),
    ("du", "づ"),
    ("de", "で"),
    ("do", "ど"),
    ("dya", "ぢゃ"),
    ("dyu", "ぢゅ"),
    ("dyo", "ぢょ"),
    // ば行
    ("ba", "ば"),
    ("bi", "び"),
    ("bu", "ぶ"),
    ("be", "べ"),
    ("bo", "ぼ"),
    ("bya", "びゃ"),
    ("byu", "びゅ"),
    ("byo", "びょ"),
    // ぱ行
    ("pa", "ぱ"),
    ("pi", "ぴ"),
    ("pu", "ぷ"),
    ("pe", "ぺ"),
    ("po", "ぽ"),
    ("pya", "ぴゃ"),
    ("pyu", "ぴゅ"),
    ("pyo", "ぴょ"),
    // ゔ行
    ("va", "ゔぁ"),
    ("vi", "ゔぃ"),
    ("vu", "ゔ"),
    ("ve", "ゔぇ"),
    ("vo", "ゔぉ"),
    // 小書き・記号
    ("xa", "ぁ"),
    ("xi", "ぃ"),
    ("xu", "ぅ"),
    ("xe", "ぇ"),
    ("xo", "ぉ"),
    ("la", "ぁ"),
    ("li", "ぃ"),
    ("lu", "ぅ"),
    ("le", "ぇ"),
    ("lo", "ぉ"),
    ("xya", "ゃ"),
    ("xyu", "ゅ"),
    ("xyo", "ょ"),
    ("lya", "ゃ"),
    ("lyu", "ゅ"),
    ("lyo", "ょ"),
    ("xtu", "っ"),
    ("ltu", "っ"),
    ("xtsu", "っ"),
    ("ltsu", "っ"),
    ("xwa", "ゎ"),
    ("lwa", "ゎ"),
    ("-", "ー"),
];

fn lookup(s: &str) -> Option<&'static str> {
    TABLE.iter().find(|(r, _)| *r == s).map(|(_, k)| *k)
}

fn is_vowel_or_y(c: u8) -> bool {
    matches!(c, b'a' | b'i' | b'u' | b'e' | b'o' | b'y')
}

fn is_consonant(c: u8) -> bool {
    c.is_ascii_lowercase() && !is_vowel_or_y(c)
}

/// 罗马字 → 平假名。含促音（双辅音）与拨音规则；遇到无法解析的片段返回 `None`。
pub fn to_hiragana(input: &str) -> Option<String> {
    let s: String = input
        .to_lowercase()
        .chars()
        .filter(|c| c.is_ascii_alphabetic() || *c == '\'' || *c == '-')
        .collect();
    let b = s.as_bytes();
    let mut out = String::new();
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        if c == b'\'' {
            i += 1;
            continue;
        }
        // 促音：相同辅音连续（n 除外）
        if i + 1 < b.len() && c == b[i + 1] && is_consonant(c) && c != b'n' {
            out.push('っ');
            i += 1;
            continue;
        }
        // 拨音：n 后面不是母音/y/' 时单独成ん
        if c == b'n' {
            match b.get(i + 1).copied() {
                None => {
                    out.push('ん');
                    i += 1;
                    continue;
                }
                Some(b'\'') => {
                    out.push('ん');
                    i += 2;
                    continue;
                }
                Some(next) if !is_vowel_or_y(next) => {
                    out.push('ん');
                    i += 1;
                    continue;
                }
                Some(_) => {}
            }
        }
        let max = 3.min(b.len() - i);
        let mut matched = None;
        for len in (1..=max).rev() {
            let frag = &s[i..i + len];
            if let Some(k) = lookup(frag) {
                matched = Some((k, len));
                break;
            }
        }
        match matched {
            Some((k, len)) => {
                out.push_str(k);
                i += len;
            }
            None => return None,
        }
    }
    Some(out)
}

/// 平假名 → 片假名（Unicode 码位 +0x60）。
pub fn to_katakana(hira: &str) -> String {
    hira.chars()
        .map(|c| match c as u32 {
            0x3041..=0x3096 => char::from_u32(c as u32 + 0x60).unwrap_or(c),
            _ => c,
        })
        .collect()
}

pub struct JaDecoder;

impl Decoder for JaDecoder {
    fn decode(&self, input: &str) -> Vec<Candidate> {
        let Some(hira) = to_hiragana(input) else {
            return Vec::new();
        };
        if hira.is_empty() {
            return Vec::new();
        }
        let consumed = input.chars().count();
        let kata = to_katakana(&hira);
        vec![
            Candidate::new(hira, consumed, CandidateKind::Kana, 2.0),
            Candidate::new(kata, consumed, CandidateKind::Kana, 1.0).with_comment("カタカナ"),
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn basic_words() {
        assert_eq!(to_hiragana("nihon").unwrap(), "にほん");
        // 字面转换是「わ」；助詞「は」的规范化需要 M2 的词典转换
        assert_eq!(to_hiragana("konnichiwa").unwrap(), "こんにちわ");
        assert_eq!(to_hiragana("konnichi ha").unwrap(), "こんにちは");
        assert_eq!(to_hiragana("arigatou").unwrap(), "ありがとう");
        assert_eq!(to_hiragana("tokyo").unwrap(), "ときょ");
        assert_eq!(to_hiragana("kitte").unwrap(), "きって");
        assert_eq!(to_hiragana("shinjuku").unwrap(), "しんじゅく");
    }

    #[test]
    fn sokuon_and_hatsuon() {
        assert_eq!(to_hiragana("gakkou").unwrap(), "がっこう");
        assert_eq!(to_hiragana("shinbun").unwrap(), "しんぶん");
        assert_eq!(to_hiragana("shin'ya").unwrap(), "しんや");
        assert_eq!(to_hiragana("kan").unwrap(), "かん");
    }

    #[test]
    fn unknown_returns_none() {
        assert!(to_hiragana("qi").is_none());
        assert!(to_hiragana("").unwrap().is_empty());
        assert_eq!(to_hiragana("ra-men").unwrap(), "らーめん");
    }

    #[test]
    fn katakana_conversion() {
        assert_eq!(to_katakana("にほん"), "ニホン");
    }

    #[test]
    fn decoder_outputs_hira_and_kata() {
        let d = JaDecoder;
        let c = d.decode("nihon");
        assert_eq!(c.len(), 2);
        assert_eq!(c[0].text, "にほん");
        assert_eq!(c[1].text, "ニホン");
        assert!(d.decode("").is_empty());
    }
}
