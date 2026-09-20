//! 本地 AI 增强的**纯数据层**：可选模型目录、内存预算与推荐、设置快照。
//!
//! 本 crate 零依赖、无网络、无文件读写：
//! - 前端负责下载、校验（sha256）、存储与权限；
//! - 本 crate 只回答「有哪些模型、要多少内存、这台机器推荐哪个」。
//!
//! 设计约束见 `docs/adr/0004-local-ai-optional-models.md`：不允许云 API，
//! 下载必须由用户显式发起，语音识别必须端上执行。

/// 模型用途。一个模型可以同时服务于多个用途（如小语言模型兼顾候选与翻译）。
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum ModelKind {
    /// 候选/词库优化（重排、补全建议）
    Assist,
    /// 语音转文字
    Speech,
    /// 同声传译 / 翻译
    Translate,
}

impl ModelKind {
    pub const ALL: [ModelKind; 3] = [ModelKind::Assist, ModelKind::Speech, ModelKind::Translate];

    pub fn id(self) -> &'static str {
        match self {
            ModelKind::Assist => "assist",
            ModelKind::Speech => "speech",
            ModelKind::Translate => "translate",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            ModelKind::Assist => "候选优化",
            ModelKind::Speech => "语音输入",
            ModelKind::Translate => "同声传译",
        }
    }
}

/// 模型描述。`size_bytes`/`sha256` 用于下载校验，`ram_mb` 是运行时内存估算。
#[derive(Clone, Copy, Debug)]
pub struct ModelSpec {
    pub id: &'static str,
    pub name: &'static str,
    pub kinds: &'static [ModelKind],
    /// 参数量（人类可读，如 "270M"）
    pub params: &'static str,
    /// 量化（如 "Q8_0"；whisper 为 "f16"）
    pub quant: &'static str,
    pub file: &'static str,
    pub url: &'static str,
    pub size_bytes: u64,
    pub sha256: &'static str,
    pub ram_mb: u32,
    pub license: &'static str,
    pub languages: &'static [&'static str],
    pub note: &'static str,
}

impl ModelSpec {
    pub fn supports(&self, kind: ModelKind) -> bool {
        self.kinds.contains(&kind)
    }

    pub fn size_mb(&self) -> u64 {
        self.size_bytes / (1024 * 1024)
    }

    pub fn quant_label(&self) -> String {
        format!("{} · {}", self.params, self.quant)
    }
}

/// 目录中的模型均为可公开下载的开源权重（用户点击后才下载）。
pub const MODELS: &[ModelSpec] = &[
    ModelSpec {
        id: "gemma-3-270m-it-q8",
        name: "Gemma 3 270M IT",
        kinds: &[ModelKind::Assist, ModelKind::Translate],
        params: "270M",
        quant: "Q8_0",
        file: "gemma-3-270m-it-Q8_0.gguf",
        url: "https://huggingface.co/ggml-org/gemma-3-270m-it-GGUF/resolve/main/gemma-3-270m-it-Q8_0.gguf",
        size_bytes: 291_545_600,
        sha256: "7ab6291f41b298875d2d4b83107c8c661e326ba6d4412120af0f27debd49fd29",
        ram_mb: 500,
        license: "Gemma Terms of Use",
        languages: &["zh", "en", "ja"],
        note: "最轻的语言模型：候选重排与翻译草稿，内存占用低",
    },
    ModelSpec {
        id: "qwen2.5-0.5b-instruct-q8",
        name: "Qwen2.5 0.5B Instruct",
        kinds: &[ModelKind::Assist, ModelKind::Translate],
        params: "0.5B",
        quant: "Q8_0",
        file: "qwen2.5-0.5b-instruct-q8_0.gguf",
        url: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q8_0.gguf",
        size_bytes: 675_710_816,
        sha256: "4a774f8683c7a6ec686a4223565556409433745adf6e38fa5cba5bb0ad0e738e",
        ram_mb: 1100,
        license: "Apache-2.0",
        languages: &["zh", "en"],
        note: "中文候选与短句改写均衡，Apache-2.0 商用友好",
    },
    ModelSpec {
        id: "qwen3-0.6b-q8",
        name: "Qwen3 0.6B",
        kinds: &[ModelKind::Assist, ModelKind::Translate],
        params: "0.6B",
        quant: "Q8_0",
        file: "Qwen3-0.6B-Q8_0.gguf",
        url: "https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q8_0.gguf",
        size_bytes: 639_446_688,
        sha256: "18d608d38b934c86fc3f3a050157b2d4df8d12330de6d13af3ba201edd0e6539",
        ram_mb: 1000,
        license: "Apache-2.0",
        languages: &["zh", "en"],
        note: "新一代小模型，指令跟随更好，适合翻译草稿",
    },
    ModelSpec {
        id: "gemma-3-1b-it-q4",
        name: "Gemma 3 1B IT",
        kinds: &[ModelKind::Assist, ModelKind::Translate],
        params: "1B",
        quant: "Q4_K_M",
        file: "gemma-3-1b-it-Q4_K_M.gguf",
        url: "https://huggingface.co/ggml-org/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf",
        size_bytes: 806_058_240,
        sha256: "107078f2011b8db626bee8040bb2bf82aa23ff7f5a81c786f3cf58dbcd75db2e",
        ram_mb: 1300,
        license: "Gemma Terms of Use",
        languages: &["zh", "en", "ja"],
        note: "1B 档质量明显更好，建议 16GB 内存及以上",
    },
    ModelSpec {
        id: "qwen2.5-1.5b-instruct-q4",
        name: "Qwen2.5 1.5B Instruct",
        kinds: &[ModelKind::Assist, ModelKind::Translate],
        params: "1.5B",
        quant: "Q4_K_M",
        file: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
        url: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf",
        size_bytes: 1_117_320_736,
        sha256: "6ca5463cf24c16cd56d7ad7461524d813b07b3f29889b2fbdbb8286a7e97a14a",
        ram_mb: 2000,
        license: "Apache-2.0",
        languages: &["zh", "en"],
        note: "本目录最强中文小模型，翻译与长句重排，建议 24GB 内存",
    },
    ModelSpec {
        id: "whisper-tiny",
        name: "Whisper Tiny",
        kinds: &[ModelKind::Speech],
        params: "39M",
        quant: "f16",
        file: "ggml-tiny.bin",
        url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin",
        size_bytes: 77_691_713,
        sha256: "518970a29bedb265f23ac48d486ddbc63bedffd90967b10140ae5ac61243acf3",
        ram_mb: 250,
        license: "MIT",
        languages: &["zh", "en", "ja", "multi"],
        note: "最低配语音识别，适合随手短句",
    },
    ModelSpec {
        id: "whisper-base",
        name: "Whisper Base",
        kinds: &[ModelKind::Speech],
        params: "74M",
        quant: "f16",
        file: "ggml-base.bin",
        url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin",
        size_bytes: 147_951_465,
        sha256: "2f62d18b50c3f3feafbf990eec23a93d319660b1efbdd3fff55e52b7cde2e374",
        ram_mb: 500,
        license: "MIT",
        languages: &["zh", "en", "ja", "multi"],
        note: "中文识别质量与体积的平衡点，推荐默认",
    },
    ModelSpec {
        id: "whisper-small",
        name: "Whisper Small",
        kinds: &[ModelKind::Speech],
        params: "244M",
        quant: "f16",
        file: "ggml-small.bin",
        url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin",
        size_bytes: 487_601_967,
        sha256: "edd29d67e70b000132af65205b99bb774b77abc13d10103e14f80ce2242913e1",
        ram_mb: 1100,
        license: "MIT",
        languages: &["zh", "en", "ja", "multi"],
        note: "口音与嘈杂环境更稳，建议 16GB 内存及以上",
    },
];

pub fn by_id(id: &str) -> Option<&'static ModelSpec> {
    MODELS.iter().find(|m| m.id == id)
}

pub fn of_kind(kind: ModelKind) -> Vec<&'static ModelSpec> {
    MODELS.iter().filter(|m| m.supports(kind)).collect()
}

/// 内存占用档位（相对系统总内存）。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum RamLevel {
    /// ≤ 12.5%：推荐开启
    Suggested,
    /// ≤ 25%：可开启，占用较大
    Moderate,
    /// > 25%：不推荐（仍允许手动启用）
    Heavy,
}

impl RamLevel {
    pub fn id(self) -> &'static str {
        match self {
            RamLevel::Suggested => "suggested",
            RamLevel::Moderate => "moderate",
            RamLevel::Heavy => "heavy",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            RamLevel::Suggested => "推荐开启",
            RamLevel::Moderate => "占用较大",
            RamLevel::Heavy => "不推荐",
        }
    }
}

/// 推荐阈值：≤12.5% 推荐，≤25% 标注占用较大。
pub fn level_of(ram_mb: u32, total_ram_mb: u64) -> RamLevel {
    if total_ram_mb == 0 {
        return RamLevel::Heavy;
    }
    let ram = f64::from(ram_mb);
    let total = total_ram_mb as f64;
    if ram <= total * 0.125 {
        RamLevel::Suggested
    } else if ram <= total * 0.25 {
        RamLevel::Moderate
    } else {
        RamLevel::Heavy
    }
}

/// 在预算内挑质量最好的：12.5% 以内取 RAM 最大者；没有则退而取全局最轻者（标为不推荐）。
pub fn recommend(kind: ModelKind, total_ram_mb: u64) -> Option<&'static ModelSpec> {
    let candidates = of_kind(kind);
    let budget = (total_ram_mb as f64 * 0.125) as u32;
    let mut best: Option<&'static ModelSpec> = None;
    for m in &candidates {
        if m.ram_mb <= budget && best.is_none_or(|b| m.ram_mb > b.ram_mb) {
            best = Some(m);
        }
    }
    best.or_else(|| candidates.iter().copied().min_by_key(|m| m.ram_mb))
}

/// 目录 JSON（前端直接解码渲染）。字段名保持稳定，便于跨平台复用。
pub fn catalog_json() -> String {
    let mut out = String::with_capacity(4096);
    out.push('[');
    for (i, m) in MODELS.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push('{');
        push_field(&mut out, "id", m.id);
        out.push(',');
        push_field(&mut out, "name", m.name);
        out.push_str(",\"kinds\":[");
        for (j, k) in m.kinds.iter().enumerate() {
            if j > 0 {
                out.push(',');
            }
            push_quoted(&mut out, k.id());
        }
        out.push_str("],");
        push_field(&mut out, "params", m.params);
        out.push(',');
        push_field(&mut out, "quant", m.quant);
        out.push(',');
        push_field(&mut out, "file", m.file);
        out.push(',');
        push_field(&mut out, "url", m.url);
        out.push_str(&format!(",\"sizeBytes\":{}", m.size_bytes));
        out.push(',');
        push_field(&mut out, "sha256", m.sha256);
        out.push_str(&format!(",\"ramMb\":{}", m.ram_mb));
        out.push(',');
        push_field(&mut out, "license", m.license);
        out.push_str(",\"languages\":[");
        for (j, l) in m.languages.iter().enumerate() {
            if j > 0 {
                out.push(',');
            }
            push_quoted(&mut out, l);
        }
        out.push_str("],");
        push_field(&mut out, "note", m.note);
        out.push('}');
    }
    out.push(']');
    out
}

/// 基于总内存的推荐 JSON：每个用途一个推荐 id 与档位。
pub fn recommend_json(total_ram_mb: u64) -> String {
    let mut out = String::with_capacity(512);
    out.push_str(&format!(
        "{{\"totalRamMb\":{total_ram_mb},\"recommendations\":["
    ));
    for (i, kind) in ModelKind::ALL.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push('{');
        push_field(&mut out, "kind", kind.id());
        out.push_str(",\"modelId\":");
        match recommend(*kind, total_ram_mb) {
            Some(m) => push_quoted(&mut out, m.id),
            None => out.push_str("null"),
        }
        out.push_str(",\"ramMb\":");
        match recommend(*kind, total_ram_mb) {
            Some(m) => out.push_str(&m.ram_mb.to_string()),
            None => out.push('0'),
        }
        out.push_str(",\"level\":");
        match recommend(*kind, total_ram_mb) {
            Some(m) => push_quoted(&mut out, level_of(m.ram_mb, total_ram_mb).id()),
            None => out.push_str("\"heavy\""),
        }
        out.push_str(",\"levelLabel\":");
        match recommend(*kind, total_ram_mb) {
            Some(m) => push_quoted(&mut out, level_of(m.ram_mb, total_ram_mb).label()),
            None => push_quoted(&mut out, "无可用模型"),
        }
        out.push('}');
    }
    out.push_str("]}");
    out
}

fn push_field(out: &mut String, key: &str, value: &str) {
    push_quoted(out, key);
    out.push(':');
    push_quoted(out, value);
}

fn push_quoted(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_ids_are_unique_and_hashes_valid() {
        let mut ids = std::collections::HashSet::new();
        for m in MODELS {
            assert!(ids.insert(m.id), "重复 id: {}", m.id);
            assert_eq!(m.sha256.len(), 64, "{} sha256 长度不对", m.id);
            assert!(
                m.sha256.chars().all(|c| c.is_ascii_hexdigit()),
                "{} sha256 非法",
                m.id
            );
            assert!(m.size_bytes > 0 && m.ram_mb > 0);
            assert!(!m.kinds.is_empty());
            assert!(m.url.starts_with("https://"));
        }
    }

    #[test]
    fn every_kind_has_models() {
        for kind in ModelKind::ALL {
            assert!(!of_kind(kind).is_empty(), "{kind:?} 没有可用模型");
        }
    }

    #[test]
    fn recommend_respects_budget() {
        let speech = recommend(ModelKind::Speech, 16 * 1024).unwrap();
        assert!(speech.ram_mb <= 2048, "16GB 机器推荐的内存应 ≤12.5%");
        assert_eq!(speech.id, "whisper-small");

        let big = recommend(ModelKind::Assist, 64 * 1024).unwrap();
        assert_eq!(big.id, "qwen2.5-1.5b-instruct-q4");

        let tiny = recommend(ModelKind::Assist, 4 * 1024).unwrap();
        assert_eq!(tiny.id, "gemma-3-270m-it-q8");
    }

    #[test]
    fn levels() {
        assert_eq!(level_of(500, 16 * 1024), RamLevel::Suggested);
        assert_eq!(level_of(2000, 16 * 1024), RamLevel::Suggested);
        assert_eq!(level_of(3000, 16 * 1024), RamLevel::Moderate);
        assert_eq!(level_of(4000, 8 * 1024), RamLevel::Heavy);
    }

    #[test]
    fn json_smoke() {
        let cat = catalog_json();
        assert!(cat.starts_with('[') && cat.ends_with(']'));
        assert!(cat.contains("\"id\":\"gemma-3-270m-it-q8\""));
        assert!(cat.contains("\"kinds\":[\"assist\",\"translate\"]"));
        assert!(!cat.contains("\\u0000"));

        let rec = recommend_json(16 * 1024);
        assert!(rec.starts_with('{') && rec.ends_with('}'));
        assert!(rec.contains("\"modelId\":\"whisper-small\""));
    }

    #[test]
    fn by_id_roundtrip() {
        for m in MODELS {
            assert_eq!(by_id(m.id).map(|x| x.name), Some(m.name));
        }
        assert!(by_id("nope").is_none());
    }
}
