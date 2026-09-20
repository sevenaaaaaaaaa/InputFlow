//! 双拼方案表。
//!
//! 表来源：Rime 官方 schema 的 `speller/algebra` 规则
//! （`rime-double-pinyin` 仓库的 `double_pinyin_flypy.schema.yaml` /
//! `double_pinyin_mspy.schema.yaml` / `double_pinyin.schema.yaml`），
//! 按规则逐条推导为「韵母 → 键位」表，可用 `cargo test -p inputflow-pinyin` 中的
//! 用例校对（如小鹤「中国 vsgo」「你好 nihc」）。
//!
//! 解码端采取**宽容策略**：接受方案的规范拼写与 Rime 的 derive 备选拼写，
//! 因此个别键位争议不会导致用户打不出字。

use std::collections::HashMap;

use inputflow_core::Scheme;
use inputflow_core::syllables::{SYLLABLES, split_initial};

/// 最长音节字符数（chuang / shuang）。
pub const MAX_SYLLABLE_LEN: usize = 6;

type FinalTable = &'static [(&'static str, &'static [&'static str])];

/// 韵母 → 键位（可能多个同义键）。ü 统一记作 v。
fn finals(scheme: Scheme) -> FinalTable {
    match scheme {
        // 小鹤双拼：小鹤音形官方键位
        Scheme::Flypy => &[
            ("a", &["a"]),
            ("o", &["o"]),
            ("e", &["e"]),
            ("i", &["i"]),
            ("u", &["u"]),
            ("v", &["v"]),
            ("ai", &["d"]),
            ("ei", &["w"]),
            ("ui", &["v"]),
            ("ao", &["c"]),
            ("ou", &["z"]),
            ("iu", &["q"]),
            ("ie", &["p"]),
            ("ue", &["t"]),
            ("ve", &["t"]),
            ("er", &["r"]),
            ("an", &["j"]),
            ("en", &["f"]),
            ("in", &["b"]),
            ("un", &["y"]),
            ("vn", &["y"]),
            ("ang", &["h"]),
            ("eng", &["g"]),
            ("ing", &["k"]),
            ("ong", &["s"]),
            ("iong", &["s"]),
            ("ia", &["x"]),
            ("ua", &["x"]),
            ("uo", &["o"]),
            ("uai", &["k"]),
            ("uan", &["r"]),
            ("uang", &["l"]),
            ("iao", &["n"]),
            ("ian", &["m"]),
            ("iang", &["l"]),
        ],
        // 微软双拼：`v$|uai$→Y`、`ing$→;`、`[uv]e$→T`（derive T→V 故 ue/ve 也接受 v）
        Scheme::Mspy => &[
            ("a", &["a"]),
            ("o", &["o"]),
            ("e", &["e"]),
            ("i", &["i"]),
            ("u", &["u"]),
            ("v", &["y"]),
            ("ai", &["l"]),
            ("ei", &["z"]),
            ("ui", &["v"]),
            ("ao", &["k"]),
            ("ou", &["b"]),
            ("iu", &["q"]),
            ("ie", &["x"]),
            ("ue", &["t", "v"]),
            ("ve", &["t", "v"]),
            ("er", &["r"]),
            ("an", &["j"]),
            ("en", &["f"]),
            ("in", &["n"]),
            ("un", &["p"]),
            ("vn", &["p"]),
            ("ang", &["h"]),
            ("eng", &["g"]),
            ("ing", &[";"]),
            ("ong", &["s"]),
            ("iong", &["s"]),
            ("ia", &["w"]),
            ("ua", &["w"]),
            ("uo", &["o"]),
            ("uai", &["y"]),
            ("uan", &["r"]),
            ("uang", &["d"]),
            ("iao", &["c"]),
            ("ian", &["m"]),
            ("iang", &["d"]),
        ],
        // 自然码：`ing$|uai$→Y`、`[uv]n$→P`、iao=C、ao=K
        Scheme::Zrm => &[
            ("a", &["a"]),
            ("o", &["o"]),
            ("e", &["e"]),
            ("i", &["i"]),
            ("u", &["u"]),
            ("v", &["v"]),
            ("ai", &["l"]),
            ("ei", &["z"]),
            ("ui", &["v"]),
            ("ao", &["k"]),
            ("ou", &["b"]),
            ("iu", &["q"]),
            ("ie", &["x"]),
            ("ue", &["t"]),
            ("ve", &["t"]),
            ("er", &["r"]),
            ("an", &["j"]),
            ("en", &["f"]),
            ("in", &["n"]),
            ("un", &["p"]),
            ("vn", &["p"]),
            ("ang", &["h"]),
            ("eng", &["g"]),
            ("ing", &["y"]),
            ("ong", &["s"]),
            ("iong", &["s"]),
            ("ia", &["w"]),
            ("ua", &["w"]),
            ("uo", &["o"]),
            ("uai", &["y"]),
            ("uan", &["r"]),
            ("uang", &["d"]),
            ("iao", &["c"]),
            ("ian", &["m"]),
            ("iang", &["d"]),
        ],
    }
}

/// 双拼码 → 候选音节集合（一个码可能对应多个音节，如 s = ong/iong）。
#[derive(Default, Debug)]
pub struct Codes {
    map: HashMap<String, Vec<&'static str>>,
}

impl Codes {
    pub fn build(scheme: Scheme) -> Self {
        let table = finals(scheme);
        let keys_of = |f: &str| -> Vec<&'static str> {
            table
                .iter()
                .find(|(name, _)| *name == f)
                .map(|(_, keys)| keys.to_vec())
                .unwrap_or_default()
        };
        let mut map: HashMap<String, Vec<&'static str>> = HashMap::new();
        for syl in SYLLABLES {
            let (ini, fin) = split_initial(syl);
            let mut encodings: Vec<String> = Vec::new();
            if ini.is_empty() {
                encodings = zero_initial_codes(scheme, syl, &keys_of(fin));
            } else {
                let ini_key = match ini {
                    "zh" => 'v',
                    "ch" => 'i',
                    "sh" => 'u',
                    other => other.chars().next().expect("声母非空"),
                };
                for k in keys_of(fin) {
                    encodings.push(format!("{ini_key}{k}"));
                }
                // jqxy + u/ue/un 的 ü 变体（Rime `derive/^([jqxy])u$/$1v/`）
                if matches!(ini, "j" | "q" | "x" | "y") && fin.starts_with('u') {
                    let alt = format!("v{}", &fin[1..]);
                    for k in keys_of(&alt) {
                        encodings.push(format!("{ini_key}{k}"));
                    }
                }
            }
            encodings.sort();
            encodings.dedup();
            for code in encodings {
                debug_assert_eq!(code.chars().count(), 2, "双拼码长度应为 2: {code}");
                map.entry(code).or_default().push(syl);
            }
        }
        Self { map }
    }

    pub fn syllables(&self, code: &str) -> &[&'static str] {
        self.map.get(code).map(Vec::as_slice).unwrap_or(&[])
    }

    pub fn code_count(&self) -> usize {
        self.map.len()
    }
}

/// 零声母音节：
/// - 小鹤/自然码：首字母重复 + 韵母键（ai→al(自然码)/ad(小鹤)）
/// - 微软：额外接受 `o + 韵母键`（Rime `derive/^([aoe].*)$/o$1/`）
fn zero_initial_codes(scheme: Scheme, syl: &str, keys: &[&'static str]) -> Vec<String> {
    if keys.is_empty() {
        return vec![syl.to_string()];
    }
    let first = syl.chars().next().expect("音节非空");
    let mut out = Vec::new();
    if matches!(first, 'a' | 'e' | 'o') {
        for k in keys {
            out.push(format!("{first}{k}"));
        }
    }
    if scheme == Scheme::Mspy {
        for k in keys {
            out.push(format!("o{k}"));
        }
    }
    if out.is_empty() {
        out.push(syl.to_string());
    }
    out.sort();
    out.dedup();
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decode(scheme: Scheme, code: &str) -> Vec<&'static str> {
        Codes::build(scheme).syllables(code).to_vec()
    }

    #[test]
    fn flypy_known_examples() {
        // 中国 = vsgo（zh→v, ong→s, g→g, uo→o）
        assert!(decode(Scheme::Flypy, "vs").contains(&"zhong"));
        assert!(decode(Scheme::Flypy, "go").contains(&"guo"));
        // 你好 = nihc（n+i, h+ao→c）
        assert!(decode(Scheme::Flypy, "ni").contains(&"ni"));
        assert!(decode(Scheme::Flypy, "hc").contains(&"hao"));
        // 输入法 = uurufa（shu→uu, ru→ru, fa→fa）
        assert!(decode(Scheme::Flypy, "uu").contains(&"shu"));
        assert!(decode(Scheme::Flypy, "ru").contains(&"ru"));
        assert!(decode(Scheme::Flypy, "fa").contains(&"fa"));
        // 零声母：爱 ad、安 aj、奥 ac、鞥 eg
        assert!(decode(Scheme::Flypy, "ad").contains(&"ai"));
        assert!(decode(Scheme::Flypy, "aj").contains(&"an"));
        assert!(decode(Scheme::Flypy, "ac").contains(&"ao"));
        assert!(decode(Scheme::Flypy, "eg").contains(&"eng"));
        assert!(decode(Scheme::Flypy, "er").contains(&"er"));
    }

    #[test]
    fn mspy_known_examples() {
        assert!(decode(Scheme::Mspy, "vs").contains(&"zhong"));
        assert!(decode(Scheme::Mspy, "hk").contains(&"hao")); // ao = k
        assert!(decode(Scheme::Mspy, "ol").contains(&"ai")); // 零声母 o+韵母键
        assert!(decode(Scheme::Mspy, "al").contains(&"ai"));
        assert!(decode(Scheme::Mspy, "yy").contains(&"yu")); // v$ → Y
        assert!(decode(Scheme::Mspy, "b;").contains(&"bing")); // ing = ;
        assert!(decode(Scheme::Mspy, "by").is_empty());
    }

    #[test]
    fn zrm_known_examples() {
        assert!(decode(Scheme::Zrm, "hk").contains(&"hao"));
        assert!(decode(Scheme::Zrm, "by").contains(&"bing")); // ing = y
        assert!(decode(Scheme::Zrm, "yv").contains(&"yu")); // v 保留
        assert!(decode(Scheme::Zrm, "yy").contains(&"ying")); // ing = y
        assert!(decode(Scheme::Zrm, "gy").contains(&"guai")); // uai = y
        assert!(decode(Scheme::Zrm, "aj").contains(&"an"));
    }

    #[test]
    fn every_syllable_has_at_least_one_code() {
        for scheme in Scheme::ALL {
            let codes = Codes::build(scheme);
            for syl in SYLLABLES {
                let n = codes.map.values().filter(|v| v.contains(&syl)).count();
                assert!(n >= 1, "{scheme:?} 缺少音节 {syl} 的编码");
            }
            assert!(codes.code_count() > 300);
        }
    }

    #[test]
    fn all_codes_are_two_chars_and_nonempty() {
        for scheme in Scheme::ALL {
            for (code, syls) in Codes::build(scheme).map {
                assert_eq!(code.chars().count(), 2, "{scheme:?} 码 {code} 长度异常");
                assert!(!syls.is_empty());
            }
        }
    }
}
