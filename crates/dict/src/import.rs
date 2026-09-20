//! 文本导入：自有 TSV 与 Rime `.dict.yaml`。
//!
//! 导入是词典进入系统的唯一入口，因此这里做严格校验（音节合法性），
//! 并把跳过的行报告给用户，而不是静默丢弃。

use inputflow_core::syllables::is_syllable;

use crate::Dictionary;

#[derive(Debug, Default, Clone)]
pub struct ImportReport {
    pub total: usize,
    pub imported: usize,
    pub skipped: usize,
    /// 最多保留 20 条，避免刷屏
    pub errors: Vec<String>,
}

impl ImportReport {
    pub(crate) fn skip(&mut self, line_no: usize, reason: &str) {
        self.skipped += 1;
        if self.errors.len() < 20 {
            self.errors.push(format!("第 {line_no} 行: {reason}"));
        }
    }
}

/// 把任意拼音写法规范化为 `音节'音节` 形式。
///
/// 支持：空格/单引号/中点/冒号/number 声调/声调符号/`u:` → `v`。
/// 任一首节不合法即返回 `None`。
pub fn normalize_pinyin(s: &str) -> Option<String> {
    let mut syllables: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut chars = s.chars().peekable();

    while let Some(c) = chars.next() {
        if c == 'u' && chars.peek() == Some(&':') {
            chars.next();
            cur.push('v');
            continue;
        }
        let mapped = match c {
            'a'..='z' => Some(c),
            'A'..='Z' => Some(c.to_ascii_lowercase()),
            '0'..='9' => None,
            _ => base_of(c),
        };
        match mapped {
            Some(ch) if ch.is_ascii_alphabetic() => cur.push(ch),
            Some(_) | None => {
                if is_separator(c) || c.is_ascii_digit() {
                    if !cur.is_empty() {
                        syllables.push(std::mem::take(&mut cur));
                    }
                } else {
                    // 声调符号等：既不是字母也不是分隔符，视作忽略
                }
            }
        }
    }
    if !cur.is_empty() {
        syllables.push(cur);
    }
    if syllables.is_empty() {
        return None;
    }

    let mut out = Vec::with_capacity(syllables.len());
    for s in &syllables {
        out.push(canonicalize(s)?);
    }
    Some(out.join("'"))
}

fn is_separator(c: char) -> bool {
    matches!(
        c,
        ' ' | '\t' | '\'' | '\u{2019}' | '·' | ':' | '-' | ',' | '/' | '|' | '_'
    )
}

/// 声调符号 → 基础字母（ü 系映射为 v）。
fn base_of(c: char) -> Option<char> {
    Some(match c {
        'ā' | 'á' | 'ǎ' | 'à' => 'a',
        'ē' | 'é' | 'ě' | 'è' | 'ê' => 'e',
        'ī' | 'í' | 'ǐ' | 'ì' => 'i',
        'ō' | 'ó' | 'ǒ' | 'ò' => 'o',
        'ū' | 'ú' | 'ǔ' | 'ù' => 'u',
        'ü' | 'ǖ' | 'ǘ' | 'ǚ' | 'ǜ' => 'v',
        'ń' | 'ň' => 'n',
        'ḿ' | 'm' => 'm',
        _ => return None,
    })
}

/// 统一 ü 写法：lue→lve、nue→nve、jve→jue、yv→yu 等，再校验。
fn canonicalize(s: &str) -> Option<String> {
    let fixed = match s {
        "lue" => "lve",
        "nue" => "nve",
        "jve" => "jue",
        "qve" => "que",
        "xve" => "xue",
        "yve" => "yue",
        "jv" => "ju",
        "qv" => "qu",
        "xv" => "xu",
        "yv" => "yu",
        other => other,
    };
    if is_syllable(fixed) {
        Some(fixed.to_string())
    } else {
        None
    }
}

/// 自有 TSV：`词\t拼音\t词频(可选)`；`#` 开头为注释。
pub fn parse_tsv(s: &str) -> (Dictionary, ImportReport) {
    let mut dict = Dictionary::new();
    let mut report = ImportReport::default();
    for (i, raw) in s.lines().enumerate() {
        let line_no = i + 1;
        let line = raw.trim_end_matches(['\r', '\n']);
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        report.total += 1;
        let mut fields = line.split('\t');
        let (Some(word), Some(pinyin)) = (fields.next(), fields.next()) else {
            report.skip(line_no, "缺少制表符分隔的「词/拼音」两列");
            continue;
        };
        let word = word.trim();
        if word.is_empty() {
            report.skip(line_no, "词为空");
            continue;
        }
        let Some(key) = normalize_pinyin(pinyin) else {
            report.skip(line_no, "拼音含非法音节");
            continue;
        };
        let freq = fields
            .next()
            .and_then(|f| f.trim().parse::<u32>().ok())
            .filter(|f| *f > 0)
            .unwrap_or(1);
        dict.insert(&key, word, freq);
        report.imported += 1;
    }
    (dict, report)
}

/// Rime `.dict.yaml` 正文导入。
///
/// 只解析条目行（`词\t拼音\t权重`），跳过 YAML 头部；遇到 `...` 视为进入词库正文后的终止符。
/// 权重做**按文件归一化**（映射到 1..=1_000_000），保证不同词库的权重尺度可比。
pub fn parse_rime_dict(s: &str) -> (Dictionary, ImportReport) {
    let mut report = ImportReport::default();
    let mut rows: Vec<(String, String, f64)> = Vec::new();

    for (i, raw) in s.lines().enumerate() {
        let line_no = i + 1;
        let line = raw.trim_end_matches(['\r', '\n']);
        if line.trim() == "..." {
            // 头部结束符出现在词条之前；若已经解析到词条，则视为正文结束
            if report.total > 0 {
                break;
            }
            continue;
        }
        let trimmed = line.trim();
        if trimmed.is_empty()
            || trimmed.starts_with('#')
            || trimmed.starts_with('%')
            || trimmed.starts_with("---")
            || trimmed.contains(':')
        {
            continue;
        }
        let mut fields = line.split('\t');
        let (Some(word), Some(pinyin)) = (fields.next(), fields.next()) else {
            continue;
        };
        let word = word.trim();
        if word.is_empty() {
            continue;
        }
        report.total += 1;

        let Some(key) = normalize_pinyin(pinyin) else {
            report.skip(line_no, "拼音含非法音节");
            continue;
        };
        let weight = fields
            .next()
            .and_then(|w| w.trim().parse::<f64>().ok())
            .filter(|w| w.is_finite() && *w >= 0.0)
            .unwrap_or(1.0);
        rows.push((key, word.to_string(), weight));
    }

    let max = rows.iter().map(|r| r.2).fold(0.0f64, f64::max);
    let mut dict = Dictionary::new();
    for (key, word, weight) in rows {
        let freq = if max <= 0.0 {
            1
        } else {
            ((weight / max) * 1_000_000.0).round().max(1.0) as u32
        };
        dict.insert(&key, &word, freq);
        report.imported += 1;
    }
    (dict, report)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_forms() {
        assert_eq!(normalize_pinyin("ni hao").unwrap(), "ni'hao");
        assert_eq!(normalize_pinyin("ni3 hao3").unwrap(), "ni'hao");
        assert_eq!(normalize_pinyin("nǐ hǎo").unwrap(), "ni'hao");
        assert_eq!(normalize_pinyin("lüe").unwrap(), "lve");
        assert_eq!(normalize_pinyin("lue").unwrap(), "lve");
        assert_eq!(normalize_pinyin("nu:e").unwrap(), "nve");
        assert_eq!(normalize_pinyin("zhong'guo").unwrap(), "zhong'guo");
        assert_eq!(normalize_pinyin("Xi'An").unwrap(), "xi'an");
        assert!(normalize_pinyin("ni xx").is_none());
        assert!(normalize_pinyin("").is_none());
        assert!(normalize_pinyin("123").is_none());
    }

    #[test]
    fn tsv_import_reports_errors() {
        let src = "# 注释\n你好\tni hao\t100\n坏词\tzzz\t5\n缺列\n世界\tshi jie\n";
        let (d, r) = parse_tsv(src);
        assert_eq!(r.total, 4);
        assert_eq!(r.imported, 2);
        assert_eq!(r.skipped, 2);
        assert_eq!(d.lookup("ni'hao").len(), 1);
        assert_eq!(d.lookup("shi'jie")[0].freq, 1);
    }

    #[test]
    fn rime_import_scales_weights() {
        let src = concat!(
            "---\n",
            "name: test\n",
            "version: '1'\n",
            "...\n",
            "你好\tni hao\t100\n",
            "世界\tshi jie\t50\n",
            "北京\tbei jing\t25\n",
        );
        let (d, r) = parse_rime_dict(src);
        assert_eq!(r.imported, 3);
        assert_eq!(r.skipped, 0);
        let nihao = &d.lookup("ni'hao")[0];
        let shijie = &d.lookup("shi'jie")[0];
        let beijing = &d.lookup("bei'jing")[0];
        assert!(nihao.freq > shijie.freq && shijie.freq > beijing.freq);
        assert_eq!(nihao.freq, 1_000_000);
        assert_eq!(beijing.freq, 250_000);
    }

    #[test]
    fn rime_stops_at_vocabulary_section() {
        let src = "你好\tni hao\t10\n...\n无关\twu guan\t999\n";
        let (d, r) = parse_rime_dict(src);
        assert_eq!(r.imported, 1);
        assert!(d.lookup("wu'guan").is_empty());
    }
}
