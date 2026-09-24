//! 回归：`lue`/`nue` 是 `lve`/`nve` 的用户拼法，词库键形为 v，切分与查词必须打通。

use inputflow_dict::Dictionary;
use inputflow_pinyin::{Layout, PinyinDecoder};
use std::sync::Arc;

fn decoder() -> PinyinDecoder {
    let mut d = Dictionary::new();
    d.insert("sheng'lve", "省略", 602);
    d.insert("sheng'lve'hao", "省略号", 120);
    d.insert("sheng'le", "生了", 5000);
    d.insert("lve", "略", 3352);
    d.insert("nve", "虐", 180);
    d.insert("nve'dai", "虐待", 90);
    PinyinDecoder::new(Arc::new(d), Layout::Full)
}

#[test]
fn lue_is_a_syllable() {
    let d = decoder();
    assert_eq!(d.preedit("shenglue"), "sheng lue");
    assert_eq!(d.preedit("lue"), "lue");
    assert_eq!(d.preedit("nuedai"), "nue dai");
}

#[test]
fn shenglue_finds_shenglve_words() {
    let d = decoder();
    let cands = d.candidates("shenglue");
    let texts: Vec<&str> = cands.iter().map(|c| c.text.as_str()).collect();
    assert!(texts.contains(&"省略"), "shenglue 应命中省略: {texts:?}");
    assert!(texts.contains(&"省略号"), "前缀应补全省略号: {texts:?}");
    // 注释显示词库键形
    let shenglve = cands.iter().find(|c| c.text == "省略").unwrap();
    assert_eq!(shenglve.comment.as_deref(), Some("sheng lve"));
}

#[test]
fn lue_and_nue_single_queries() {
    let d = decoder();
    let cands = d.candidates("lue");
    let texts: Vec<&str> = cands.iter().map(|c| c.text.as_str()).collect();
    assert!(texts.contains(&"略"), "lue 应命中略: {texts:?}");
    let cands = d.candidates("nuedai");
    let texts: Vec<&str> = cands.iter().map(|c| c.text.as_str()).collect();
    assert!(texts.contains(&"虐待"), "nuedai 应命中虐待: {texts:?}");
    let cands = d.candidates("nue");
    let texts: Vec<&str> = cands.iter().map(|c| c.text.as_str()).collect();
    assert!(texts.contains(&"虐"), "nue 应命中虐: {texts:?}");
}

#[test]
fn v_form_still_works() {
    let d = decoder();
    let cands = d.candidates("shenglve");
    let texts: Vec<&str> = cands.iter().map(|c| c.text.as_str()).collect();
    assert!(texts.contains(&"省略"), "v 形拼法不回归: {texts:?}");
}

#[test]
fn lu_plus_e_not_broken_by_canon() {
    // 「录额」lu'e 是 lu+e，不应被 lue→lve 归一吞掉（prefix 查询才归一，切分不归一）
    let mut d = Dictionary::new();
    d.insert("lu'e", "录额", 10);
    d.insert("lu", "录", 100);
    d.insert("e", "额", 100);
    let dec = PinyinDecoder::new(Arc::new(d), Layout::Full);
    let cands = dec.candidates("lue");
    let texts: Vec<&str> = cands.iter().map(|c| c.text.as_str()).collect();
    assert!(texts.contains(&"录额"), "lu+e 路径保留: {texts:?}");
}
