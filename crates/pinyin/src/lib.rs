//! 拼音解码：全拼切分 + 双拼方案 + Viterbi 整句。
//!
//! 解码是纯函数：`PinyinDecoder::candidates(input)` 无状态、可单测、可并发。

pub mod decode;
pub mod scheme;

pub use decode::{Layout, PinyinDecoder, normalize};
pub use scheme::{Codes, MAX_SYLLABLE_LEN};

use inputflow_core::{Candidate, Decoder};

impl Decoder for PinyinDecoder {
    fn decode(&self, input: &str) -> Vec<Candidate> {
        self.candidates(input)
    }
}
