//! 知你喂食层（ADR-0008 E2）：截图/文档 → 术语提炼 → 营养库。
//!
//! 术语提炼是纯统计：汉字连续段内的 2–6 字 n-gram，复现 ≥2 次、停用表过滤、
//! 被更长词覆盖的子串剪掉——零模型，全本地。营养词获得词典级加分与按键召回
//! （派生拼音，教一次处处可用），忘记即全部效果消失，不污染用户词库。

use std::collections::{BTreeMap, HashMap};

/// 提炼的词长范围（字符数）。
pub const MIN_TERM_CHARS: usize = 2;
pub const MAX_TERM_CHARS: usize = 6;
/// 复现少于此数不成词（教一次的前提是文档里它真的反复出现）。
pub const MIN_COUNT: u32 = 2;
/// 单次提炼最多给出的术语数。
pub const MAX_TERMS: usize = 50;
/// 营养词的词典级基础加分（叠加 ln(强度)，对齐用户词 bonus 的量级之上）。
pub const NUTRIENT_BONUS: f64 = 3.0;
/// 营养库容量上限；超出时新增失败（营养词应是少量精挑）。
pub const MAX_ENTRIES: usize = 5_000;
/// 营养词按键召回的基础分（对齐短语候选的量级）。
pub const NUTRITION_SCORE_EXACT: f64 = 18.0;
pub const NUTRITION_SCORE_PREFIX: f64 = 12.0;

/// 停用字：虚词/代词/量词等单字，含其一即不成术语。
const STOP_CHARS: &str = "的了是在我有不这人都他她它您们也就要会到说着没看好自里后 \
    大小上下中个还又被把让使对向往于给用拿比或等之与其从而因所已再才只更很最太 \
    吗呢吧啊呀哦嘛么地得过啦呗咧喽哟哪谁什么咋";

/// 停用词：高频但绝非术语的二二字组合（含代词、时间、常用动词搭配）。
const STOP_WORDS: &[&str] = &[
    "如果", "虽然", "但是", "可是", "不过", "因为", "所以", "因此", "而且", "并且",
    "或者", "以及", "这些", "那些", "这个", "那个", "我们", "你们", "他们", "她们",
    "它们", "自己", "什么", "怎么", "怎样", "可以", "应该", "需要", "现在", "今天",
    "明天", "昨天", "时候", "地方", "问题", "方面", "情况", "进行", "开始", "已经",
    "还有", "就是", "不是", "没有", "不能", "这样", "那样", "一个", "一些", "一下",
    "一直", "一定", "一样", "起来", "出来", "之后", "之前", "以后", "以前",
];

/// 能进术语的字符：与短语库同一套汉字范围。
fn is_term_char(c: char) -> bool {
    matches!(c, '\u{3400}'..='\u{9fff}' | '\u{f900}'..='\u{faff}')
}

fn has_stop_char(gram: &str) -> bool {
    gram.chars().any(|c| STOP_CHARS.contains(c))
}

/// 术语提炼：返回 `(词, 复现次数)`，次数降序，上限 [`MAX_TERMS`]。
///
/// n-gram 只在汉字连续段内切（标点/英文/空格是天然边界，跨段不成词），
/// 被更长保留词完全覆盖的子串剪掉（「县政府」×5 时不再吐「县政」）。
pub fn extract_terms(text: &str) -> Vec<(String, u32)> {
    let mut counts: HashMap<String, u32> = HashMap::new();
    let mut run = String::new();
    for ch in text.chars().chain(Some('\0')) {
        if is_term_char(ch) {
            run.push(ch);
            continue;
        }
        if run.is_empty() {
            continue;
        }
        count_run(&mut counts, &run);
        run.clear();
    }
    let mut grams: Vec<(String, u32)> = counts
        .into_iter()
        .filter(|(g, c)| {
            *c >= MIN_COUNT
                && g.chars().count() <= MAX_TERM_CHARS
                && !has_stop_char(g)
                && !STOP_WORDS.contains(&g.as_str())
        })
        .collect();
    // 长词优先保留：若某保留词包含本词且次数不少于它，本词的出现全被解释掉了。
    grams.sort_by(|a, b| {
        b.0.chars()
            .count()
            .cmp(&a.0.chars().count())
            .then_with(|| b.1.cmp(&a.1))
    });
    let mut kept: Vec<(String, u32)> = Vec::new();
    for (g, c) in grams {
        if !kept.iter().any(|(k, kc)| kc >= &c && k.contains(&g)) {
            kept.push((g, c));
        }
    }
    kept.sort_by(|a, b| {
        b.1.cmp(&a.1)
            .then_with(|| b.0.chars().count().cmp(&a.0.chars().count()))
            .then_with(|| a.0.cmp(&b.0))
    });
    kept.truncate(MAX_TERMS);
    kept
}

fn count_run(counts: &mut HashMap<String, u32>, run: &str) {
    let chars: Vec<char> = run.chars().collect();
    for n in MIN_TERM_CHARS..=MAX_TERM_CHARS {
        if chars.len() < n {
            break;
        }
        for start in 0..=chars.len() - n {
            let gram: String = chars[start..start + n].iter().collect();
            *counts.entry(gram).or_insert(0) += 1;
        }
    }
}

/// 一条营养词：词 → {按键串, 出处, 强度, 时间}。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NutritionEntry {
    /// 派生拼音（小写字母串）；空串 = 派生失败（只享受加分，不做按键召回）。
    pub keys: String,
    pub source: String,
    /// 复现次数之和：重复喂同一词会增强它。
    pub strength: u32,
    pub added_at: u64,
}

/// 营养库。BTreeMap 保证导出/列举顺序稳定。
#[derive(Debug, Default)]
pub struct NutritionLibrary {
    terms: BTreeMap<String, NutritionEntry>,
}

impl NutritionLibrary {
    pub fn new() -> Self {
        Self::default()
    }

    /// 新增或增强一条营养词；返回是否写入（重复喂同一词：强度累加、时间刷新）。
    pub fn add(
        &mut self,
        term: &str,
        keys: &str,
        source: &str,
        strength: u32,
        now: u64,
    ) -> bool {
        let term = term.trim();
        if term.is_empty() || !term.chars().all(is_term_char) {
            return false;
        }
        if !self.terms.contains_key(term) && self.terms.len() >= MAX_ENTRIES {
            return false;
        }
        let entry = self.terms.entry(term.to_string()).or_insert_with(|| NutritionEntry {
            keys: String::new(),
            source: String::new(),
            strength: 0,
            added_at: now,
        });
        if entry.keys.is_empty() {
            entry.keys = keys.to_string();
        }
        entry.source = sanitize_source(source);
        entry.strength = entry.strength.saturating_add(strength.max(1));
        entry.added_at = now;
        true
    }

    pub fn forget(&mut self, term: &str) -> bool {
        self.terms.remove(term.trim()).is_some()
    }

    pub fn forget_all(&mut self) {
        self.terms.clear();
    }

    pub fn len(&self) -> usize {
        self.terms.len()
    }

    pub fn is_empty(&self) -> bool {
        self.terms.is_empty()
    }

    pub fn get(&self, term: &str) -> Option<&NutritionEntry> {
        self.terms.get(term.trim())
    }

    /// 按加入时间倒序列举（权限中心展示用）。
    pub fn list(&self) -> Vec<(&str, &NutritionEntry)> {
        let mut out: Vec<(&str, &NutritionEntry)> = self
            .terms
            .iter()
            .map(|(t, e)| (t.as_str(), e))
            .collect();
        out.sort_by(|a, b| b.1.added_at.cmp(&a.1.added_at).then_with(|| a.0.cmp(b.0)));
        out
    }

    /// 词典级加分：营养词必得基础分，喂得越多越强。
    pub fn bonus(&self, text: &str) -> f64 {
        match self.terms.get(text) {
            Some(e) => NUTRIENT_BONUS + (e.strength.max(1) as f64).ln(),
            None => 0.0,
        }
    }

    /// 按键前缀召回营养词，返回 `(按键串, 词, 强度)`，强度降序、短键优先。
    pub fn prefix_matches(&self, prefix: &str, limit: usize) -> Vec<(&str, &str, u32)> {
        if prefix.is_empty() || limit == 0 {
            return Vec::new();
        }
        let mut hits: Vec<(&str, &str, u32)> = self
            .terms
            .iter()
            .filter(|(_, e)| !e.keys.is_empty() && e.keys.starts_with(prefix))
            .map(|(t, e)| (e.keys.as_str(), t.as_str(), e.strength))
            .collect();
        hits.sort_by(|a, b| {
            b.2.cmp(&a.2)
                .then_with(|| a.0.len().cmp(&b.0.len()))
                .then_with(|| a.1.cmp(b.1))
        });
        hits.truncate(limit);
        hits
    }

    /// 导出 TSV：`词\t按键串\t出处\t强度\t加入时间`。出处里的制表符已清洗。
    pub fn export_tsv(&self) -> String {
        let mut out = String::new();
        for (term, e) in &self.terms {
            out.push_str(term);
            out.push('\t');
            out.push_str(&e.keys);
            out.push('\t');
            out.push_str(&e.source);
            out.push('\t');
            out.push_str(&e.strength.to_string());
            out.push('\t');
            out.push_str(&e.added_at.to_string());
            out.push('\n');
        }
        out
    }

    /// 导入 TSV（覆盖同名条目），返回成功行数；坏行跳过。
    pub fn import_tsv(&mut self, tsv: &str) -> usize {
        let mut n = 0;
        for line in tsv.lines() {
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() != 5 {
                continue;
            }
            let (Ok(strength), Ok(added_at)) = (f[3].parse::<u32>(), f[4].parse::<u64>()) else {
                continue;
            };
            let term = f[0].trim();
            if term.is_empty() || !term.chars().all(is_term_char) {
                continue;
            }
            self.terms.insert(
                term.to_string(),
                NutritionEntry {
                    keys: f[1].to_string(),
                    source: sanitize_source(f[2]),
                    strength,
                    added_at,
                },
            );
            n += 1;
        }
        n
    }
}

fn sanitize_source(s: &str) -> String {
    let cleaned: String = s
        .chars()
        .map(|c| if c == '\t' || c == '\n' || c == '\r' { ' ' } else { c })
        .collect();
    cleaned.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repeated_terms_surface() {
        let text = "县政府发布通知，县政府要求各县级单位落实，县政府办公室汇总。";
        let terms = extract_terms(text);
        assert!(
            terms.iter().any(|(t, c)| t == "县政府" && *c >= 2),
            "反复出现的词应被提炼: {terms:?}"
        );
    }

    #[test]
    fn covered_substrings_are_pruned() {
        let text = "张江高科张江高科张江高科";
        let terms = extract_terms(text);
        // 张江高科 ×3：张江、江高、高科、张江高 都被它完全覆盖
        assert_eq!(terms.first().map(|(t, _)| t.as_str()), Some("张江高科"));
        assert!(!terms.iter().any(|(t, _)| t == "张江"), "{terms:?}");
        assert!(!terms.iter().any(|(t, _)| t == "江高"), "{terms:?}");
    }

    #[test]
    fn partial_overlap_keeps_both() {
        // 政府 在「县政府」之外还独立出现 3 次：两个词都留
        let text = "县政府县政府县政府县政府县政府政府文件政府文件政府文件";
        let terms = extract_terms(text);
        assert!(terms.iter().any(|(t, _)| t == "县政府"), "{terms:?}");
        assert!(terms.iter().any(|(t, _)| t == "政府"), "{terms:?}");
    }

    #[test]
    fn grams_do_not_cross_boundaries() {
        let text = "北京。北京。海军。";
        let terms = extract_terms(text);
        assert!(terms.iter().any(|(t, c)| t == "北京" && *c == 2), "{terms:?}");
        assert!(!terms.iter().any(|(t, _)| t == "京北"), "跨标点不成词: {terms:?}");
    }

    #[test]
    fn stop_words_and_single_occurrence_dropped() {
        let text = "我们开会我们开会讨论了一次方案";
        let terms = extract_terms(text);
        assert!(!terms.iter().any(|(t, _)| t == "我们"), "{terms:?}");
        assert!(!terms.iter().any(|(t, _)| t == "方案"), "只出现一次不成词: {terms:?}");
    }

    #[test]
    fn long_nonsense_runs_are_capped() {
        let text = "杝杬杭杮杫杬杭杮杫杬杭杮杫杬杭杮杫杬杭杮";
        let terms = extract_terms(text);
        assert!(terms.len() <= MAX_TERMS);
        assert!(!terms.iter().any(|(t, _)| t.chars().count() > MAX_TERM_CHARS));
    }

    #[test]
    fn library_add_bonus_and_recall() {
        let mut lib = NutritionLibrary::new();
        assert!(lib.add("张江高科", "zhangjianggaoke", "项目文档.txt", 3, 1_000));
        assert_eq!(lib.len(), 1);
        assert!(lib.bonus("张江高科") > NUTRIENT_BONUS);
        assert_eq!(lib.bonus("张江"), 0.0);

        let hits = lib.prefix_matches("zhangjiang", 5);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].1, "张江高科");
        assert!(lib.prefix_matches("zhangxu", 5).is_empty());
        assert!(lib.prefix_matches("", 5).is_empty());

        // 重复喂：强度累加，出处与时间刷新
        lib.add("张江高科", "zhangjianggaoke", "合同.pdf", 2, 2_000);
        let e = lib.get("张江高科").unwrap();
        assert_eq!(e.strength, 5);
        assert_eq!(e.source, "合同.pdf");
        assert_eq!(e.added_at, 2_000);

        assert!(lib.forget("张江高科"));
        assert!(!lib.forget("张江高科"));
        assert_eq!(lib.bonus("张江高科"), 0.0);
    }

    #[test]
    fn library_rejects_bad_terms() {
        let mut lib = NutritionLibrary::new();
        assert!(!lib.add("", "a", "s", 1, 1));
        assert!(!lib.add("hello", "hello", "s", 1, 1), "英文词不进营养库");
        assert!(lib.add("张江", "zhangjiang", "带\t制表符", 1, 1));
        assert_eq!(lib.get("张江").unwrap().source, "带 制表符", "出处清洗");
    }

    #[test]
    fn library_tsv_roundtrip() {
        let mut lib = NutritionLibrary::new();
        lib.add("张江高科", "zhangjianggaoke", "项目文档.txt", 3, 1_000);
        lib.add("县级市", "xianjishi", "通知.docx", 2, 2_000);
        let tsv = lib.export_tsv();
        assert!(tsv.contains("张江高科\tzhangjianggaoke\t项目文档.txt\t3\t1000"), "{tsv}");

        let mut fresh = NutritionLibrary::new();
        assert_eq!(fresh.import_tsv(&tsv), 2);
        assert!(fresh.bonus("张江高科") > 0.0);
        assert_eq!(fresh.get("县级市").unwrap().keys, "xianjishi");
        assert_eq!(fresh.import_tsv("坏行\n缺\t列\t数\t1\n"), 0);
    }
}
