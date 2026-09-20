//! 拼音音节表与声韵切分。全表按字典序排列，供二分查找。

/// 有效音节（不含声调；ü 统一写作 v）。**必须保持字典序**（有测试校验）。
pub const SYLLABLES: [&str; 409] = [
    "a", "ai", "an", "ang", "ao", "ba", "bai", "ban", "bang", "bao", "bei", "ben", "beng", "bi",
    "bian", "biao", "bie", "bin", "bing", "bo", "bu", "ca", "cai", "can", "cang", "cao", "ce",
    "cen", "ceng", "cha", "chai", "chan", "chang", "chao", "che", "chen", "cheng", "chi", "chong",
    "chou", "chu", "chua", "chuai", "chuan", "chuang", "chui", "chun", "chuo", "ci", "cong", "cou",
    "cu", "cuan", "cui", "cun", "cuo", "da", "dai", "dan", "dang", "dao", "de", "dei", "den",
    "deng", "di", "dia", "dian", "diao", "die", "ding", "diu", "dong", "dou", "du", "duan", "dui",
    "dun", "duo", "e", "ei", "en", "eng", "er", "fa", "fan", "fang", "fei", "fen", "feng", "fo",
    "fou", "fu", "ga", "gai", "gan", "gang", "gao", "ge", "gei", "gen", "geng", "gong", "gou",
    "gu", "gua", "guai", "guan", "guang", "gui", "gun", "guo", "ha", "hai", "han", "hang", "hao",
    "he", "hei", "hen", "heng", "hong", "hou", "hu", "hua", "huai", "huan", "huang", "hui", "hun",
    "huo", "ji", "jia", "jian", "jiang", "jiao", "jie", "jin", "jing", "jiong", "jiu", "ju",
    "juan", "jue", "jun", "ka", "kai", "kan", "kang", "kao", "ke", "ken", "keng", "kong", "kou",
    "ku", "kua", "kuai", "kuan", "kuang", "kui", "kun", "kuo", "la", "lai", "lan", "lang", "lao",
    "le", "lei", "leng", "li", "lia", "lian", "liang", "liao", "lie", "lin", "ling", "liu", "lo",
    "long", "lou", "lu", "luan", "lun", "luo", "lv", "lve", "ma", "mai", "man", "mang", "mao",
    "me", "mei", "men", "meng", "mi", "mian", "miao", "mie", "min", "ming", "miu", "mo", "mou",
    "mu", "na", "nai", "nan", "nang", "nao", "ne", "nei", "nen", "neng", "ni", "nian", "niang",
    "niao", "nie", "nin", "ning", "niu", "nong", "nou", "nu", "nuan", "nuo", "nv", "nve", "o",
    "ou", "pa", "pai", "pan", "pang", "pao", "pei", "pen", "peng", "pi", "pian", "piao", "pie",
    "pin", "ping", "po", "pou", "pu", "qi", "qia", "qian", "qiang", "qiao", "qie", "qin", "qing",
    "qiong", "qiu", "qu", "quan", "que", "qun", "ran", "rang", "rao", "re", "ren", "reng", "ri",
    "rong", "rou", "ru", "rua", "ruan", "rui", "run", "ruo", "sa", "sai", "san", "sang", "sao",
    "se", "sen", "seng", "sha", "shai", "shan", "shang", "shao", "she", "shei", "shen", "sheng",
    "shi", "shou", "shu", "shua", "shuai", "shuan", "shuang", "shui", "shun", "shuo", "si", "song",
    "sou", "su", "suan", "sui", "sun", "suo", "ta", "tai", "tan", "tang", "tao", "te", "teng",
    "ti", "tian", "tiao", "tie", "ting", "tong", "tou", "tu", "tuan", "tui", "tun", "tuo", "wa",
    "wai", "wan", "wang", "wei", "wen", "weng", "wo", "wu", "xi", "xia", "xian", "xiang", "xiao",
    "xie", "xin", "xing", "xiong", "xiu", "xu", "xuan", "xue", "xun", "ya", "yan", "yang", "yao",
    "ye", "yi", "yin", "ying", "yo", "yong", "you", "yu", "yuan", "yue", "yun", "za", "zai", "zan",
    "zang", "zao", "ze", "zei", "zen", "zeng", "zha", "zhai", "zhan", "zhang", "zhao", "zhe",
    "zhei", "zhen", "zheng", "zhi", "zhong", "zhou", "zhu", "zhua", "zhuai", "zhuan", "zhuang",
    "zhui", "zhun", "zhuo", "zi", "zong", "zou", "zu", "zuan", "zui", "zun", "zuo",
];

/// 声母表（含 y/w，按长度优先匹配）。
pub const INITIALS: [&str; 23] = [
    "zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x", "r",
    "z", "c", "s", "y", "w",
];

pub fn is_syllable(s: &str) -> bool {
    SYLLABLES.binary_search(&s).is_ok()
}

/// 切分声母/韵母；无韵母时返回 ("", 原串)。零声母返回 ("", final)。
pub fn split_initial(s: &str) -> (&str, &str) {
    for ini in INITIALS {
        if let Some(rest) = s.strip_prefix(ini) {
            if !rest.is_empty() {
                return (ini, rest);
            }
        }
    }
    ("", s)
}

/// 是否为合法的「音节前缀」（用于把尾部未输完的串识别为 partial，不上屏）。
pub fn is_syllable_prefix(s: &str) -> bool {
    if s.is_empty() {
        return false;
    }
    SYLLABLES
        .iter()
        .any(|full| full.len() > s.len() && full.starts_with(s))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn table_is_sorted_and_unique() {
        for w in SYLLABLES.windows(2) {
            assert!(w[0] < w[1], "音节表不是字典序: {} >= {}", w[0], w[1]);
        }
    }

    #[test]
    fn lookup_basics() {
        assert!(is_syllable("ni"));
        assert!(is_syllable("shuang"));
        assert!(is_syllable("lv"));
        assert!(is_syllable("er"));
        assert!(!is_syllable("n"));
        assert!(!is_syllable("xx"));
        assert!(!is_syllable("v"));
    }

    #[test]
    fn splits() {
        assert_eq!(split_initial("zhong"), ("zh", "ong"));
        assert_eq!(split_initial("chuan"), ("ch", "uan"));
        assert_eq!(split_initial("shui"), ("sh", "ui"));
        assert_eq!(split_initial("ni"), ("n", "i"));
        assert_eq!(split_initial("ao"), ("", "ao"));
        assert_eq!(split_initial("er"), ("", "er"));
        assert_eq!(split_initial("yue"), ("y", "ue"));
        assert_eq!(split_initial("lve"), ("l", "ve"));
    }

    #[test]
    fn prefixes() {
        assert!(is_syllable_prefix("zho"));
        assert!(is_syllable_prefix("z"));
        assert!(is_syllable_prefix("shu"));
        assert!(is_syllable_prefix("ni")); // nian / niang 等更长音节
        assert!(!is_syllable_prefix("ao")); // 无以 ao 开头的更长音节
        assert!(!is_syllable_prefix("er"));
        assert!(!is_syllable_prefix(""));
        assert!(!is_syllable_prefix("ss"));
    }
}
