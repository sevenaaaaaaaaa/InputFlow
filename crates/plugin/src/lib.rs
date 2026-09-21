//! 插件包框架：社区扩展的唯一形态是**声明式数据包**。
//!
//! 隐私与安全模型（这条边界不可谈判）：
//! - 包里只有清单（plugin.json）+ 数据文件（颜色表/图片/词典），**没有任何可执行代码**；
//! - 包声明自己需要什么权限，权限取白名单制，声明之外的一律拒绝加载；
//! - 内核只做解析与校验，渲染由平台前端完成——内核崩溃面不因装包而扩大。
//!
//! 三种包：`skin`（候选窗皮肤）、`pet`（桌宠形象）、`dict`（外部词典 IFD1）。

use std::fmt;
use std::path::{Path, PathBuf};

/// 权限白名单：包能声明的一切权限都在这里，声明白名单之外的权限 = 拒绝加载。
/// 目前所有包都是纯数据，唯一存在的权限是词典包读取明文词库文件。
pub const KNOWN_PERMISSIONS: &[&str] = &["read:plain-text-dict"];

/// 包的种类。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PackKind {
    Skin,
    Pet,
    Dict,
}

impl PackKind {
    pub fn from_id(s: &str) -> Option<Self> {
        match s {
            "skin" => Some(Self::Skin),
            "pet" => Some(Self::Pet),
            "dict" => Some(Self::Dict),
            _ => None,
        }
    }

    pub fn id(&self) -> &'static str {
        match self {
            Self::Skin => "skin",
            Self::Pet => "pet",
            Self::Dict => "dict",
        }
    }

    /// 该种类默认的入口数据文件（清单 entry 缺省时）。
    pub fn default_entry(&self) -> &'static str {
        match self {
            Self::Skin => "theme.json",
            Self::Pet => "pet.json",
            Self::Dict => "dict.ifd",
        }
    }
}

/// 加载错误。展示给用户时直接可读。
#[derive(Debug, Clone, PartialEq)]
pub struct PackError(pub String);

impl fmt::Display for PackError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// 一个通过校验的插件包。
#[derive(Debug, Clone, PartialEq)]
pub struct Pack {
    /// 全局唯一 id：`^[a-z0-9][a-z0-9-]{1,63}$`，同时是目录名。
    pub id: String,
    pub name: String,
    pub version: String,
    pub kind: PackKind,
    pub authors: Vec<String>,
    pub description: String,
    pub license: String,
    pub permissions: Vec<String>,
    pub entry: String,
    /// 包所在目录（校验通过后由扫描器填上）。
    pub dir: PathBuf,
}

/// 简易 JSON 读取器：只解析本清单需要的那点结构（扁平字符串字段 + 字符串数组），
/// 不引第三方解析器——内核其它 crate 也是这个标准。
struct MiniJson<'a> {
    s: &'a [u8],
}

impl<'a> MiniJson<'a> {
    fn new(s: &'a str) -> Self {
        Self { s: s.as_bytes() }
    }

    fn skip_ws(&mut self) {
        while let Some(&b) = self.s.first() {
            if b == b' ' || b == b'\t' || b == b'\n' || b == b'\r' {
                self.s = &self.s[1..];
            } else {
                break;
            }
        }
    }

    fn eat(&mut self, byte: u8) -> bool {
        self.skip_ws();
        if self.s.first() == Some(&byte) {
            self.s = &self.s[1..];
            true
        } else {
            false
        }
    }

    fn peek(&mut self) -> Option<u8> {
        self.skip_ws();
        self.s.first().copied()
    }

    fn string(&mut self) -> Option<String> {
        if !self.eat(b'"') {
            return None;
        }
        let mut out = String::new();
        loop {
            let rest = self.s;
            let b = *rest.first()?;
            match b {
                b'"' => {
                    self.s = &rest[1..];
                    return Some(out);
                }
                b'\\' => {
                    let esc = *rest.get(1)?;
                    self.s = &rest[2..];
                    match esc {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'n' => out.push('\n'),
                        b't' => out.push('\t'),
                        b'u' => {
                            if rest.len() < 6 {
                                return None;
                            }
                            let hex = std::str::from_utf8(&rest[2..6]).ok()?;
                            self.s = &rest[6..];
                            let cp = u32::from_str_radix(hex, 16).ok()?;
                            out.push(char::from_u32(cp).unwrap_or('\u{fffd}'));
                        }
                        _ => return None,
                    }
                }
                _ => {
                    let width = utf8_width(b);
                    if width == 0 || rest.len() < width {
                        return None;
                    }
                    out.push_str(std::str::from_utf8(&rest[..width]).ok()?);
                    self.s = &rest[width..];
                }
            }
        }
    }

    /// 顶层对象 → (键, 值) 列表；值支持字符串 / 字符串数组。
    fn object(&mut self) -> Option<Vec<(String, JsonValue)>> {
        if !self.eat(b'{') {
            return None;
        }
        let mut fields = Vec::new();
        if self.eat(b'}') {
            return Some(fields);
        }
        loop {
            let key = self.string()?;
            if !self.eat(b':') {
                return None;
            }
            let value = match self.peek()? {
                b'"' => JsonValue::Str(self.string()?),
                b'[' => {
                    if !self.eat(b'[') {
                        return None;
                    }
                    let mut items = Vec::new();
                    if self.eat(b']') {
                        JsonValue::Arr(items)
                    } else {
                        loop {
                            items.push(self.string()?);
                            match self.peek()? {
                                b',' => {
                                    if !self.eat(b',') {
                                        return None;
                                    }
                                }
                                b']' => break,
                                _ => return None,
                            }
                        }
                        if !self.eat(b']') {
                            return None;
                        }
                        JsonValue::Arr(items)
                    }
                }
                _ => return None,
            };
            fields.push((key, value));
            match self.peek()? {
                b',' => {
                    if !self.eat(b',') {
                        return None;
                    }
                }
                b'}' => {
                    if !self.eat(b'}') {
                        return None;
                    }
                    return Some(fields);
                }
                _ => return None,
            }
        }
    }
}

enum JsonValue {
    Str(String),
    Arr(Vec<String>),
}

fn utf8_width(b: u8) -> usize {
    match b {
        0x00..=0x7f => 1,
        0xc2..=0xdf => 2,
        0xe0..=0xef => 3,
        0xf0..=0xf4 => 4,
        _ => 0,
    }
}

fn valid_id(id: &str) -> bool {
    let bytes = id.as_bytes();
    (2..=64).contains(&bytes.len())
        && bytes.first().is_some_and(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
        && bytes
            .iter()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'-')
}

fn valid_version(v: &str) -> bool {
    // 宽松 semver：三段数字即可
    let parts: Vec<&str> = v.split('.').collect();
    parts.len() == 3 && parts.iter().all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
}

impl Pack {
    /// 从目录加载并校验。任何一步不过都给出用户可读的原因。
    pub fn from_dir(dir: &Path) -> Result<Self, PackError> {
        let manifest_path = dir.join("plugin.json");
        let raw = std::fs::read_to_string(&manifest_path)
            .map_err(|_| PackError(format!("缺少或读不了 {}", manifest_path.display())))?;
        let mut json = MiniJson::new(&raw);
        let fields = json
            .object()
            .ok_or_else(|| PackError("plugin.json 不是合法的 JSON 对象".into()))?;

        let mut id = None;
        let mut name = None;
        let mut version = None;
        let mut kind = None;
        let mut authors = Vec::new();
        let mut description = String::new();
        let mut license = String::new();
        let mut permissions = Vec::new();
        let mut entry = None;
        for (key, value) in fields {
            match (key.as_str(), value) {
                ("id", JsonValue::Str(v)) => id = Some(v),
                ("name", JsonValue::Str(v)) => name = Some(v),
                ("version", JsonValue::Str(v)) => version = Some(v),
                ("kind", JsonValue::Str(v)) => kind = Some(v),
                ("description", JsonValue::Str(v)) => description = v,
                ("license", JsonValue::Str(v)) => license = v,
                ("entry", JsonValue::Str(v)) => entry = Some(v),
                ("authors", JsonValue::Arr(v)) => authors = v,
                ("permissions", JsonValue::Arr(v)) => permissions = v,
                _ => {} // 未知字段忽略（向前兼容）
            }
        }

        let id = id.ok_or_else(|| PackError("缺少 id".into()))?;
        if !valid_id(&id) {
            return Err(PackError(format!("id 非法（小写字母/数字/连字符，2-64 位）: {id}")));
        }
        let name = name.ok_or_else(|| PackError("缺少 name".into()))?;
        let version = version.ok_or_else(|| PackError("缺少 version".into()))?;
        if !valid_version(&version) {
            return Err(PackError(format!("version 需要是三段数字（如 1.0.0）: {version}")));
        }
        let kind = PackKind::from_id(
            kind.as_deref().ok_or_else(|| PackError("缺少 kind".into()))?,
        )
        .ok_or_else(|| PackError("kind 只能是 skin / pet / dict".into()))?;

        for perm in &permissions {
            if !KNOWN_PERMISSIONS.contains(&perm.as_str()) {
                return Err(PackError(format!(
                    "声明了未知权限 {perm:?}——权限是白名单制，白名单: {KNOWN_PERMISSIONS:?}"
                )));
            }
        }
        if kind != PackKind::Dict && !permissions.is_empty() {
            return Err(PackError("只有 dict 包可以声明 read:plain-text-dict".into()));
        }

        let entry = entry.unwrap_or_else(|| kind.default_entry().to_string());
        // 入口文件名做路径逃逸检查
        if entry.contains("..") || entry.contains('/') || entry.contains('\\') {
            return Err(PackError(format!("entry 必须是包目录内的文件名: {entry}")));
        }
        if !dir.join(&entry).is_file() {
            return Err(PackError(format!("入口文件不存在: {entry}")));
        }

        Ok(Self {
            id,
            name,
            version,
            kind,
            authors,
            description,
            license,
            permissions,
            entry,
            dir: dir.to_path_buf(),
        })
    }

    /// 扫描目录下所有包；坏包不中断，连同原因一起返回。
    pub fn scan(root: &Path) -> (Vec<Self>, Vec<(String, PackError)>) {
        let mut packs = Vec::new();
        let mut errors = Vec::new();
        let Ok(entries) = std::fs::read_dir(root) else {
            return (packs, errors);
        };
        for item in entries.flatten() {
            let path = item.path();
            if !path.is_dir() {
                continue;
            }
            match Self::from_dir(&path) {
                Ok(pack) => packs.push(pack),
                Err(e) => errors.push((path.display().to_string(), e)),
            }
        }
        packs.sort_by(|a, b| a.id.cmp(&b.id));
        errors.sort_by(|a, b| a.0.cmp(&b.0));
        (packs, errors)
    }

    /// 设置页/插件管理器用的目录 JSON（调用方注入转义函数避免重复实现）。
    pub fn catalog_json(packs: &[Self], errors: &[(String, PackError)]) -> String {
        let mut out = String::from("{\"packs\":[");
        for (i, p) in packs.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str(&format!(
                "{{\"id\":{},\"name\":{},\"version\":{},\"kind\":{},\"authors\":{},\"description\":{},\"license\":{},\"permissions\":{},\"dir\":{}}}",
                json_str(&p.id),
                json_str(&p.name),
                json_str(&p.version),
                json_str(p.kind.id()),
                json_arr(&p.authors),
                json_str(&p.description),
                json_str(&p.license),
                json_arr(&p.permissions),
                json_str(&p.dir.display().to_string()),
            ));
        }
        out.push_str("],\"errors\":[");
        for (i, (dir, e)) in errors.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str(&format!(
                "{{\"dir\":{},\"error\":{}}}",
                json_str(dir),
                json_str(&e.0)
            ));
        }
        out.push_str("]}");
        out
    }
}

fn json_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
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
    out
}

fn json_arr(items: &[String]) -> String {
    let inner: Vec<String> = items.iter().map(|s| json_str(s)).collect();
    format!("[{}]", inner.join(","))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_pack(dir: &Path, manifest: &str, entry_file: &str, entry_content: &str) {
        std::fs::create_dir_all(dir).unwrap();
        std::fs::write(dir.join("plugin.json"), manifest).unwrap();
        std::fs::write(dir.join(entry_file), entry_content).unwrap();
    }

    #[test]
    fn accepts_valid_skin_pack() {
        let root = std::env::temp_dir().join(format!("ifplug-skin-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        write_pack(
            &root.join("skin-demo"),
            r#"{"id":"skin-demo","name":"月色","version":"1.0.0","kind":"skin",
                "authors":["someone"],"description":"深色皮肤","license":"CC0-1.0",
                "permissions":[]}"#,
            "theme.json",
            "{\"light\":{}}",
        );
        let (packs, errors) = Pack::scan(&root);
        assert!(errors.is_empty(), "{errors:?}");
        assert_eq!(packs.len(), 1);
        let p = &packs[0];
        assert_eq!(p.id, "skin-demo");
        assert_eq!(p.kind, PackKind::Skin);
        assert_eq!(p.entry, "theme.json");
        assert!(p.dir.ends_with("skin-demo"));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn rejects_unknown_permissions() {
        let root = std::env::temp_dir().join(format!("ifplug-perm-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        write_pack(
            &root.join("bad"),
            r#"{"id":"bad","name":"坏包","version":"1.0.0","kind":"skin",
                "permissions":["read:all-keystrokes"]}"#,
            "theme.json",
            "{}",
        );
        let (packs, errors) = Pack::scan(&root);
        assert!(packs.is_empty());
        assert_eq!(errors.len(), 1);
        assert!(errors[0].1 .0.contains("未知权限"), "{}", errors[0].1);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn dict_pack_may_declare_dict_permission() {
        let root = std::env::temp_dir().join(format!("ifplug-dict-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        write_pack(
            &root.join("dict-x"),
            r#"{"id":"dict-x","name":"外部词典","version":"0.2.0","kind":"dict",
                "permissions":["read:plain-text-dict"]}"#,
            "dict.ifd",
            "IFD1",
        );
        let (packs, errors) = Pack::scan(&root);
        assert!(errors.is_empty(), "{errors:?}");
        assert_eq!(packs[0].permissions, vec!["read:plain-text-dict"]);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn rejects_bad_id_version_kind_and_missing_entry() {
        let root = std::env::temp_dir().join(format!("ifplug-bad-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("p1")).unwrap();
        std::fs::write(
            root.join("p1/plugin.json"),
            r#"{"id":"Bad_ID","name":"x","version":"1.0.0","kind":"skin"}"#,
        )
        .unwrap();
        std::fs::create_dir_all(root.join("p2")).unwrap();
        std::fs::write(
            root.join("p2/plugin.json"),
            r#"{"id":"p2","name":"x","version":"1.0","kind":"skin"}"#,
        )
        .unwrap();
        std::fs::create_dir_all(root.join("p3")).unwrap();
        std::fs::write(
            root.join("p3/plugin.json"),
            r#"{"id":"p3","name":"x","version":"1.0.0","kind":"robot"}"#,
        )
        .unwrap();
        std::fs::create_dir_all(root.join("p4")).unwrap();
        std::fs::write(
            root.join("p4/plugin.json"),
            r#"{"id":"p4","name":"x","version":"1.0.0","kind":"skin","entry":"../evil.json"}"#,
        )
        .unwrap();

        let (packs, errors) = Pack::scan(&root);
        assert!(packs.is_empty());
        assert_eq!(errors.len(), 4);
        assert!(errors[0].1 .0.contains("id 非法"));
        assert!(errors[1].1 .0.contains("version"));
        assert!(errors[2].1 .0.contains("kind"));
        assert!(errors[3].1 .0.contains("entry"));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn catalog_json_shape() {
        let root = std::env::temp_dir().join(format!("ifplug-cat-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        write_pack(
            &root.join("pet-x"),
            r#"{"id":"pet-x","name":"电子猫","version":"1.0.0","kind":"pet","authors":["a","b"]}"#,
            "pet.json",
            "{}",
        );
        let (packs, errors) = Pack::scan(&root);
        let json = Pack::catalog_json(&packs, &errors);
        assert!(json.contains("\"id\":\"pet-x\""), "{json}");
        assert!(json.contains("\"kind\":\"pet\""), "{json}");
        assert!(json.contains("\"authors\":[\"a\",\"b\"]"), "{json}");
        assert!(json.contains("\"errors\":[]"), "{json}");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn missing_manifest_is_a_clean_error() {
        let root = std::env::temp_dir().join(format!("ifplug-none-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("empty")).unwrap();
        let (packs, errors) = Pack::scan(&root);
        assert!(packs.is_empty());
        assert!(errors[0].1 .0.contains("缺少或读不了"));
        let _ = std::fs::remove_dir_all(&root);
    }
}
