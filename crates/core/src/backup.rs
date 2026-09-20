//! 备份包格式：带版本头与校验和的纯文本信封，零依赖。
//!
//! 为什么是文本而不是二进制：备份要能被用户自己看懂、能用任何工具检查，
//! 也要能在不同平台的加密存储之间搬运（macOS 钥匙串 / Windows DPAPI / Android Keystore
//! 的密钥各不相同，落盘密文不可移植，明文包才是通用中间格式）。
//!
//! 信封本身不加密。前端负责：写盘时用本机密钥加密（`.ifbak`），
//! 用户显式要求导出明文时必须二次确认（见 ADR-0005）。
//!
//! ```text
//! #IFBAK1
//! #kind: userdata
//! #items: 3
//! #crc32: 8a1b2c3d
//! 你好⇥2
//! @pair⇥北京⇥世界⇥1
//! @phrase⇥beijingshijie⇥北京世界⇥2
//! ```
//!
//! （`⇥` 是制表符：正文就是 `UserModel::export_tsv` 的输出，原样放进信封。）

/// 信封魔术头。
pub const MAGIC: &str = "#IFBAK1";
/// 用户词/二元组/短语的内容类型。
pub const KIND_USERDATA: &str = "userdata";

#[derive(Debug, PartialEq, Eq)]
pub struct Backup {
    pub kind: String,
    pub items: usize,
    pub body: String,
}

#[derive(Debug, PartialEq, Eq)]
pub enum BackupError {
    /// 不是备份包（缺魔术头或版本不认识）
    NotBackup,
    /// 校验和对不上：文件被截断或被改过
    Checksum,
}

impl std::fmt::Display for BackupError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BackupError::NotBackup => write!(f, "不是 InputFlow 备份包"),
            BackupError::Checksum => write!(f, "备份包校验失败（文件可能已损坏）"),
        }
    }
}

impl std::error::Error for BackupError {}

/// 打包：`items` 由调用方给（条目数，仅供人眼核对）。
pub fn pack(kind: &str, items: usize, body: &str) -> String {
    // 先把正文规整成「非空即以换行结尾」，校验和算在规整后的正文上，
    // 这样解包时逐行重组出来的正文一定和这里一致。
    let normalized = if body.is_empty() || body.ends_with('\n') {
        body.to_string()
    } else {
        format!("{body}\n")
    };
    let mut out = String::with_capacity(normalized.len() + 96);
    out.push_str(MAGIC);
    out.push('\n');
    out.push_str("#kind: ");
    out.push_str(kind);
    out.push_str("\n#items: ");
    out.push_str(&items.to_string());
    out.push_str("\n#crc32: ");
    out.push_str(&format!("{:08x}", crc32(normalized.as_bytes())));
    out.push('\n');
    out.push_str(&normalized);
    out
}

/// 解包并校验。校验失败时不返回内容，避免把半截数据并进用户词库。
pub fn unpack(text: &str) -> Result<Backup, BackupError> {
    let mut lines = text.lines();
    if lines.next().map(str::trim) != Some(MAGIC) {
        return Err(BackupError::NotBackup);
    }
    let mut kind = String::new();
    let mut items = 0usize;
    let mut crc: Option<u32> = None;
    let mut body = String::new();
    let mut in_body = false;
    for line in lines {
        if !in_body {
            if let Some(v) = line.strip_prefix("#kind:") {
                kind = v.trim().to_string();
                continue;
            }
            if let Some(v) = line.strip_prefix("#items:") {
                items = v.trim().parse().unwrap_or(0);
                continue;
            }
            if let Some(v) = line.strip_prefix("#crc32:") {
                crc = u32::from_str_radix(v.trim(), 16).ok();
                continue;
            }
            in_body = true;
        }
        body.push_str(line);
        body.push('\n');
    }
    let Some(crc) = crc else {
        return Err(BackupError::NotBackup);
    };
    if crc32(body.as_bytes()) != crc {
        return Err(BackupError::Checksum);
    }
    Ok(Backup { kind, items, body })
}

/// CRC-32（IEEE，逐位实现）。备份包不大，省一张查找表。
pub fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xffff_ffffu32;
    for &b in data {
        crc ^= b as u32;
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xedb8_8320 & mask);
        }
    }
    !crc
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crc32_matches_known_vector() {
        assert_eq!(crc32(b"123456789"), 0xcbf4_3926);
        assert_eq!(crc32(b""), 0);
    }

    #[test]
    fn pack_unpack_roundtrip() {
        let body = "你好\t2\n@pair\t北京\t世界\t1\n";
        let packed = pack(KIND_USERDATA, 2, body);
        assert!(packed.starts_with(MAGIC));
        let b = unpack(&packed).expect("应能解包");
        assert_eq!(b.kind, KIND_USERDATA);
        assert_eq!(b.items, 2);
        assert_eq!(b.body, body);
    }

    #[test]
    fn body_without_trailing_newline_is_normalized() {
        let packed = pack(KIND_USERDATA, 1, "你好\t2");
        assert_eq!(unpack(&packed).unwrap().body, "你好\t2\n");
    }

    #[test]
    fn tampered_body_is_rejected() {
        let packed = pack(KIND_USERDATA, 1, "你好\t2\n");
        let tampered = packed.replace("你好\t2", "你好\t9999");
        assert_eq!(unpack(&tampered), Err(BackupError::Checksum));
    }

    #[test]
    fn plain_text_is_not_a_backup() {
        assert_eq!(unpack("你好\t2\n"), Err(BackupError::NotBackup));
        assert_eq!(unpack(""), Err(BackupError::NotBackup));
        assert_eq!(unpack("#IFBAK1\n你好\t2\n"), Err(BackupError::NotBackup));
    }

    #[test]
    fn empty_body_roundtrips() {
        let packed = pack(KIND_USERDATA, 0, "");
        let b = unpack(&packed).unwrap();
        assert_eq!(b.items, 0);
        assert_eq!(b.body, "");
    }
}
