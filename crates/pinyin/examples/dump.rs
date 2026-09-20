//! 手动检查候选排序：`cargo run -p inputflow-pinyin --example dump [dict.ifd]`

use std::sync::Arc;

use inputflow_dict::Dictionary;
use inputflow_pinyin::{Layout, PinyinDecoder};

fn main() {
    let dict = match std::env::args().nth(1) {
        Some(path) => {
            let bytes = std::fs::read(&path).expect("读取词典失败");
            Arc::new(Dictionary::from_bytes(&bytes).expect("解析词典失败"))
        }
        None => Arc::new(Dictionary::embedded()),
    };
    eprintln!(
        "词典：{} key / {} 词条",
        dict.key_count(),
        dict.entry_count()
    );
    for (layout, inputs) in [
        (
            Layout::Full,
            vec![
                "n",
                "ni",
                "nih",
                "nihao",
                "nh",
                "bj",
                "wm",
                "nhao",
                "wo",
                "shi",
                "beij",
                "zhongguo",
                "woshi",
                "woxihuanni",
                "jintiantianqizenmeyang",
                "woshiyimingchengxuyuan",
                "mingtianqunaliwan",
                "xian",
                "an",
                "nihm",
                "shurufa",
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
