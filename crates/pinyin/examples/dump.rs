//! 手动检查候选排序：`cargo run -p inputflow-pinyin --example dump`

use std::sync::Arc;

use inputflow_dict::Dictionary;
use inputflow_pinyin::{Layout, PinyinDecoder};

fn main() {
    let dict = Arc::new(Dictionary::embedded());
    for (layout, inputs) in [
        (
            Layout::Full,
            vec![
                "zhongguo", "beijing", "nihao", "woshi", "xian", "an", "shi", "nihm", "shurufa",
            ],
        ),
        (
            Layout::Shuangpin(inputflow_core::Scheme::Flypy),
            vec!["vsgo", "nihc", "uurufa", "aj"],
        ),
    ] {
        let d = PinyinDecoder::new(dict.clone(), layout);
        for input in inputs {
            println!("--- {layout:?} {input}  preedit={:?}", d.preedit(input));
            for c in d.candidates(input).iter().take(8) {
                println!(
                    "   {:>6}  score={:7.2} consumed={} kind={:?} comment={:?}",
                    c.text, c.score, c.consumed, c.kind, c.comment
                );
            }
        }
    }
}
