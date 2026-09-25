//! C ABI。所有函数内部捕获 panic，绝不跨 FFI 边界展开。
//!
//! 安全契约（与 `include/inputflow.h` 一致）：传入的指针必须指向有效对象；
//! `inputflow_new*` 的字符串参数必须是 NUL 结尾的 UTF-8；返回的 `char*` 必须用
//! `inputflow_free_string` 释放。所有 `unsafe` 导出函数都在此契约下工作。
#![allow(clippy::missing_safety_doc)]

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::sync::Arc;

use inputflow_core::Mode;
use inputflow_dict::Dictionary;
use inputflow_engine::Session;
use inputflow_engine::app_mode::AppModeMemory;
use inputflow_engine::evolution::{self, EvolutionMemory};
use inputflow_plugin::Pack as PluginPack;

pub struct InputFlowSession {
    inner: Session,
}

/// 每应用中英模式记忆（独立于输入会话：跨应用共享一份）。
pub struct InputFlowAppMode {
    inner: AppModeMemory,
}

/// 知你自进化账本（ADR-0008 决策层）。
pub struct InputFlowEvolution {
    inner: EvolutionMemory,
}

/// 解析候选 JSON `[{"text":"现","score":10.5},...]` → (词, base 分) 列表。
/// 只认这个固定形状，宽容空白；坏对象跳过。
fn parse_candidates(json: &str) -> Vec<(String, f32)> {
    let mut out = Vec::new();
    let bytes = json.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'{' {
            i += 1;
            continue;
        }
        let end = match json[i..].find('}') {
            Some(e) => i + e,
            None => break,
        };
        let obj = &json[i..=end];
        let text = obj
            .find("\"text\"")
            .and_then(|p| obj[p + 6..].find('"').map(|q| p + 6 + q + 1))
            .and_then(|s| obj[s..].find('"').map(|e| obj[s..s + e].to_string()));
        let score = obj
            .find("\"score\"")
            .and_then(|p| {
                let rest = &obj[p + 7..];
                let num: String = rest
                    .chars()
                    .skip_while(|c| !c.is_ascii_digit() && *c != '-')
                    .take_while(|c| c.is_ascii_digit() || *c == '.' || *c == '-' || *c == 'e')
                    .collect();
                num.parse::<f32>().ok()
            });
        if let (Some(t), Some(sc)) = (text, score) {
            out.push((t, sc));
        }
        i = end + 1;
    }
    out
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
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
    out
}

impl InputFlowSession {
    fn new(dict: Arc<Dictionary>, mode: Mode) -> Self {
        Self {
            inner: Session::with_mode(dict, mode),
        }
    }
}

unsafe fn cstr(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .ok()
        .map(str::to_string)
}

fn mode_of(s: Option<String>) -> Mode {
    s.as_deref().and_then(Mode::from_id).unwrap_or(Mode::Pinyin)
}

fn into_c(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(c) => c.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

fn guard_ptr<F: FnOnce() -> *mut c_char>(f: F) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(std::ptr::null_mut())
}

fn guard_int<F: FnOnce() -> i32>(f: F) -> i32 {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(-1)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_new(mode: *const c_char) -> *mut InputFlowSession {
    let mode = unsafe { cstr(mode) };
    catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new(InputFlowSession::new(
            Arc::new(Dictionary::embedded()),
            mode_of(mode),
        )))
    }))
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_new_with_dict(
    mode: *const c_char,
    dict_path: *const c_char,
) -> *mut InputFlowSession {
    let mode = unsafe { cstr(mode) };
    let path = unsafe { cstr(dict_path) };
    catch_unwind(AssertUnwindSafe(|| {
        let dict = path
            .as_deref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|b| Dictionary::from_bytes(&b).ok())
            .unwrap_or_else(Dictionary::embedded);
        Box::into_raw(Box::new(InputFlowSession::new(
            Arc::new(dict),
            mode_of(mode),
        )))
    }))
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_free(session: *mut InputFlowSession) {
    if session.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        drop(unsafe { Box::from_raw(session) });
    }));
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_feed(
    session: *mut InputFlowSession,
    utf8_char: *const c_char,
) -> i32 {
    if session.is_null() {
        return 0;
    }
    let s = unsafe { cstr(utf8_char) };
    guard_int(|| {
        let Some(ch) = s.as_deref().and_then(|x| x.chars().next()) else {
            return 0;
        };
        let session = unsafe { &mut *session };
        i32::from(session.inner.feed(ch))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_backspace(session: *mut InputFlowSession) -> i32 {
    if session.is_null() {
        return 0;
    }
    guard_int(|| {
        let session = unsafe { &mut *session };
        i32::from(session.inner.backspace())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_clear(session: *mut InputFlowSession) {
    if session.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let session = unsafe { &mut *session };
        session.inner.clear();
    }));
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_set_mode(
    session: *mut InputFlowSession,
    mode: *const c_char,
) -> i32 {
    if session.is_null() {
        return 0;
    }
    let mode = unsafe { cstr(mode) };
    guard_int(|| {
        let Some(m) = mode.as_deref().and_then(Mode::from_id) else {
            return 0;
        };
        let session = unsafe { &mut *session };
        session.inner.set_mode(m);
        1
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_mode(session: *mut InputFlowSession) -> *mut c_char {
    if session.is_null() {
        return std::ptr::null_mut();
    }
    guard_ptr(|| {
        let session = unsafe { &*session };
        into_c(session.inner.mode().id().to_string())
    })
}

/// 简繁显示开关：非 0 表示候选转成繁体。返回 1 表示设置成功。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_set_traditional(session: *mut InputFlowSession, on: i32) -> i32 {
    if session.is_null() {
        return 0;
    }
    guard_int(|| {
        let session = unsafe { &mut *session };
        session.inner.set_traditional(on != 0);
        1
    })
}

/// 当前是否繁体显示。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_traditional(session: *mut InputFlowSession) -> i32 {
    if session.is_null() {
        return 0;
    }
    guard_int(|| {
        let session = unsafe { &*session };
        i32::from(session.inner.traditional())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_composition_json(session: *mut InputFlowSession) -> *mut c_char {
    if session.is_null() {
        return std::ptr::null_mut();
    }
    guard_ptr(|| {
        let session = unsafe { &*session };
        into_c(composition_json(&session.inner))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_select(
    session: *mut InputFlowSession,
    index: u32,
) -> *mut c_char {
    if session.is_null() {
        return std::ptr::null_mut();
    }
    guard_ptr(|| {
        let session = unsafe { &mut *session };
        match session.inner.select(index as usize) {
            Some(text) => into_c(text),
            None => std::ptr::null_mut(),
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_commit_raw(session: *mut InputFlowSession) -> *mut c_char {
    if session.is_null() {
        return std::ptr::null_mut();
    }
    guard_ptr(|| {
        let session = unsafe { &mut *session };
        match session.inner.commit_raw() {
            Some(text) => into_c(text),
            None => std::ptr::null_mut(),
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_user_export(session: *mut InputFlowSession) -> *mut c_char {
    if session.is_null() {
        return std::ptr::null_mut();
    }
    guard_ptr(|| {
        let session = unsafe { &*session };
        into_c(session.inner.user_model().export_tsv())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_user_import(
    session: *mut InputFlowSession,
    tsv: *const c_char,
) -> i32 {
    if session.is_null() {
        return -1;
    }
    let tsv = unsafe { cstr(tsv) };
    guard_int(|| {
        let Some(tsv) = tsv else { return -1 };
        let session = unsafe { &mut *session };
        session.inner.user_model_mut().import_tsv(&tsv) as i32
    })
}

/// 外部文本上屏（语音等）的学习入口：记词并更新二元组上下文。
/// 成功返回 0，参数无效返回 -1。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_record_commit(
    session: *mut InputFlowSession,
    text: *const c_char,
) -> i32 {
    if session.is_null() {
        return -1;
    }
    let text = unsafe { cstr(text) };
    guard_int(|| {
        let Some(text) = text else { return -1 };
        let session = unsafe { &mut *session };
        session.inner.commit_external(&text);
        0
    })
}

/// 导出用户数据备份包（明文 TSV + 版本头 + CRC32）。前端负责加密落盘。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_backup_export(session: *mut InputFlowSession) -> *mut c_char {
    if session.is_null() {
        return std::ptr::null_mut();
    }
    guard_ptr(|| {
        let session = unsafe { &*session };
        into_c(session.inner.export_backup())
    })
}

/// 导入备份包。`merge` 非 0 时同名条目取较大次数；返回条目数，失败返回 -1。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_backup_import(
    session: *mut InputFlowSession,
    text: *const c_char,
    merge: i32,
) -> i32 {
    if session.is_null() {
        return -1;
    }
    let text = unsafe { cstr(text) };
    guard_int(|| {
        let Some(text) = text else { return -1 };
        let session = unsafe { &mut *session };
        match session.inner.import_backup(&text, merge != 0) {
            Ok(n) => n as i32,
            Err(_) => -1,
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_free_string(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        drop(unsafe { CString::from_raw(s) });
    }));
}

#[unsafe(no_mangle)]
pub extern "C" fn inputflow_version() -> *const c_char {
    static VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), "\0");
    VERSION.as_ptr().cast()
}


fn composition_json(session: &Session) -> String {
    let comp = session.composition();
    let mut out = String::with_capacity(64 + comp.candidates.len() * 48);
    out.push_str("{\"mode\":\"");
    out.push_str(session.mode().id());
    out.push_str("\",\"raw\":\"");
    out.push_str(&json_escape(&comp.raw));
    out.push_str("\",\"preedit\":\"");
    out.push_str(&json_escape(&comp.preedit));
    out.push_str("\",\"candidates\":[");
    for (i, c) in comp.candidates.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str("{\"text\":\"");
        out.push_str(&json_escape(&c.text));
        out.push_str("\",\"consumed\":");
        out.push_str(&c.consumed.to_string());
        out.push_str(",\"kind\":\"");
        out.push_str(c.kind.id());
        out.push('"');
        if let Some(comment) = &c.comment {
            out.push_str(",\"comment\":\"");
            out.push_str(&json_escape(comment));
            out.push('"');
        }
        out.push('}');
    }
    out.push_str("]}");
    out
}

/// 本地 AI 增强：模型目录 JSON（静态信息，前端用于渲染选择列表）。
#[unsafe(no_mangle)]
pub extern "C" fn inputflow_ai_catalog_json() -> *mut c_char {
    guard_ptr(|| into_c(inputflow_ai::catalog_json()))
}

/// 本地 AI 增强：按系统总内存给出每个用途的推荐模型 JSON。
#[unsafe(no_mangle)]
pub extern "C" fn inputflow_ai_recommend_json(total_ram_mb: u64) -> *mut c_char {
    guard_ptr(|| into_c(inputflow_ai::recommend_json(total_ram_mb)))
}

/// 扫描插件目录（皮肤/桌宠/词典数据包），返回目录 JSON：
/// `{"packs":[{"id","name","version","kind","authors","description","license","permissions","dir"}],
///   "errors":[{"dir","error"}]}`。坏包跳过不中断。调用方释放。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_plugin_scan_json(dir: *const c_char) -> *mut c_char {
    let dir = unsafe { cstr(dir) };
    guard_ptr(|| {
        let Some(dir) = dir else {
            return std::ptr::null_mut();
        };
        let (packs, errors) = PluginPack::scan(Path::new(&dir));
        into_c(PluginPack::catalog_json(&packs, &errors))
    })
}

/// 输入统计总结（全为计数，零内容）：返回指标 JSON：
/// `{"speed_cpm","accuracy","kcal","saved_keys","voice_chars","deletes","enters","stare_max_secs"}`。
#[unsafe(no_mangle)]
pub extern "C" fn inputflow_stats_digest_json(
    chars: u64,
    keys: u64,
    deletes: u64,
    enters: u64,
    saved_keys: u64,
    voice_chars: u64,
    active_secs: u64,
    stare_max_secs: u64,
) -> *mut c_char {
    guard_ptr(|| {
        let digest = inputflow_engine::stats::Digest::compute(&inputflow_engine::stats::DayStats {
            chars,
            keys,
            deletes,
            enters,
            saved_keys,
            voice_chars,
            active_secs,
            stare_max_secs,
        });
        into_c(digest.to_json())
    })
}

// ──────────────────── 知你自进化（ADR-0008 决策层） ────────────────────

#[unsafe(no_mangle)]
pub extern "C" fn inputflow_evolution_new() -> *mut InputFlowEvolution {
    catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new(InputFlowEvolution {
            inner: EvolutionMemory::new(),
        }))
    }))
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_evolution_free(memory: *mut InputFlowEvolution) {
    if memory.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        drop(unsafe { Box::from_raw(memory) });
    }));
}

/// 记录一次奖励：reward_x100 ∈ {100 选词, 150 重选, -200 删除, 60 次选}。
/// lex_window 为最近上屏文本；app 可为空串；hour 0-23；now Unix 秒。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_evolution_reward(
    memory: *mut InputFlowEvolution,
    word: *const c_char,
    lex_window: *const c_char,
    app: *const c_char,
    hour: u32,
    reward_x100: i32,
    now: u64,
) -> i32 {
    if memory.is_null() {
        return 0;
    }
    let (word, lex, app) = unsafe { (cstr(word), cstr(lex_window), cstr(app)) };
    guard_int(|| {
        let Some(word) = word else { return 0 };
        let lex = lex.unwrap_or_default();
        let app = app.unwrap_or_default();
        let features = evolution::context_features(&lex, if app.is_empty() { None } else { Some(&app) }, hour);
        let features = [features, evolution::topic_features(&lex, 3)].concat();
        let memory = unsafe { &mut *memory };
        memory.inner.reward(&word, &features, reward_x100 as f32 / 100.0, now);
        1
    })
}

/// 候选重排：输入 `[{"text":"现","score":10.5},...]`，
/// 输出按修正后分数降序的 `[{"text":..,"score":..,"delta":..},...]`。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_evolution_adjust_json(
    memory: *mut InputFlowEvolution,
    candidates_json: *const c_char,
    lex_window: *const c_char,
    app: *const c_char,
    hour: u32,
    now: u64,
) -> *mut c_char {
    if memory.is_null() {
        return std::ptr::null_mut();
    }
    let (cands, lex, app) = unsafe { (cstr(candidates_json), cstr(lex_window), cstr(app)) };
    guard_ptr(|| {
        let Some(cands) = cands else { return std::ptr::null_mut() };
        let lex = lex.unwrap_or_default();
        let app = app.unwrap_or_default();
        let mut features =
            evolution::context_features(&lex, if app.is_empty() { None } else { Some(&app) }, hour);
        features.extend(evolution::topic_features(&lex, 3));
        let ranked = unsafe { &*memory }.inner.rank(&parse_candidates(&cands), &features, now);
        let mut out = String::from("[");
        for (i, (text, score, delta)) in ranked.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str(&format!(
                "{{\"text\":\"{}\",\"score\":{:.3},\"delta\":{:.3}}}",
                json_escape(text),
                score,
                delta
            ));
        }
        out.push(']');
        into_c(out)
    })
}

/// 决策轨道：这个词在该上下文里的贡献特征 [{"feature":..,"affinity":..},...]。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_evolution_explain_json(
    memory: *mut InputFlowEvolution,
    word: *const c_char,
    lex_window: *const c_char,
    app: *const c_char,
    hour: u32,
    now: u64,
) -> *mut c_char {
    if memory.is_null() {
        return std::ptr::null_mut();
    }
    let (word, lex, app) = unsafe { (cstr(word), cstr(lex_window), cstr(app)) };
    guard_ptr(|| {
        let Some(word) = word else { return std::ptr::null_mut() };
        let lex = lex.unwrap_or_default();
        let app = app.unwrap_or_default();
        let mut features =
            evolution::context_features(&lex, if app.is_empty() { None } else { Some(&app) }, hour);
        features.extend(evolution::topic_features(&lex, 3));
        let trail = unsafe { &*memory }.inner.explain(&word, &features, now);
        let mut out = String::from("[");
        for (i, (f, a)) in trail.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str(&format!(
                "{{\"feature\":\"{}\",\"affinity\":{:.3}}}",
                json_escape(f),
                a
            ));
        }
        out.push(']');
        into_c(out)
    })
}

/// 学习账本 TSV 导出/导入（词\t特征\t亲和度\t观察数\t最后触摸）。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_evolution_export(memory: *mut InputFlowEvolution) -> *mut c_char {
    if memory.is_null() {
        return std::ptr::null_mut();
    }
    guard_ptr(|| {
        let memory = unsafe { &*memory };
        into_c(memory.inner.export_tsv())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_evolution_import(
    memory: *mut InputFlowEvolution,
    tsv: *const c_char,
) -> i32 {
    if memory.is_null() {
        return -1;
    }
    let tsv = unsafe { cstr(tsv) };
    guard_int(|| {
        let Some(tsv) = tsv else { return -1 };
        let memory = unsafe { &mut *memory };
        memory.inner.import_tsv(&tsv) as i32
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_evolution_forget_all(memory: *mut InputFlowEvolution) {
    if memory.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        unsafe { &mut *memory }.inner.forget_all();
    }));
}

// ──────────────────── 每应用中英模式记忆 ────────────────────
#[unsafe(no_mangle)]
pub extern "C" fn inputflow_app_mode_new() -> *mut InputFlowAppMode {
    catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new(InputFlowAppMode {
            inner: AppModeMemory::new(),
        }))
    }))
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_app_mode_free(memory: *mut InputFlowAppMode) {
    if memory.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        drop(unsafe { Box::from_raw(memory) });
    }));
}

/// 记录一次信号：`zh` 非 0 表示中文侧，`strong` 非 0 表示手动切换（Shift/菜单），
/// 否则为上屏弱信号；`now` 为 Unix 秒。返回 1 表示已记录（应用 id 非法时为 0）。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_app_mode_observe(
    memory: *mut InputFlowAppMode,
    app_id: *const c_char,
    zh: i32,
    strong: i32,
    now: u64,
) -> i32 {
    if memory.is_null() {
        return 0;
    }
    let app = unsafe { cstr(app_id) };
    guard_int(|| {
        let Some(app) = app else { return 0 };
        let memory = unsafe { &mut *memory };
        i32::from(memory.inner.observe(&app, zh != 0, strong != 0, now))
    })
}

/// 该应用现在该用中文还是英文？返回 1 = 中文，0 = 英文，-1 = 样本不足不干预。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_app_mode_decide(
    memory: *mut InputFlowAppMode,
    app_id: *const c_char,
    now: u64,
) -> i32 {
    if memory.is_null() {
        return -1;
    }
    let app = unsafe { cstr(app_id) };
    guard_int(|| {
        let Some(app) = app else { return -1 };
        let memory = unsafe { &*memory };
        match memory.inner.decide(&app, now) {
            Some(true) => 1,
            Some(false) => 0,
            None => -1,
        }
    })
}

/// 忘记单个应用的偏好。返回 1 表示存在过并已删除。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_app_mode_forget(
    memory: *mut InputFlowAppMode,
    app_id: *const c_char,
) -> i32 {
    if memory.is_null() {
        return 0;
    }
    let app = unsafe { cstr(app_id) };
    guard_int(|| {
        let Some(app) = app else { return 0 };
        let memory = unsafe { &mut *memory };
        i32::from(memory.inner.forget(&app))
    })
}

/// 清空全部学习结果（关闭学习开关时调用，不留数据）。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_app_mode_forget_all(memory: *mut InputFlowAppMode) {
    if memory.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let memory = unsafe { &mut *memory };
        memory.inner.forget_all();
    }));
}

/// 导出学习结果 TSV（前端负责持久化；只含 bundle id 与票数，无按键内容）。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_app_mode_export(memory: *mut InputFlowAppMode) -> *mut c_char {
    if memory.is_null() {
        return std::ptr::null_mut();
    }
    guard_ptr(|| {
        let memory = unsafe { &*memory };
        into_c(memory.inner.export_tsv())
    })
}

/// 导入学习结果 TSV，返回导入行数。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inputflow_app_mode_import(
    memory: *mut InputFlowAppMode,
    tsv: *const c_char,
) -> i32 {
    if memory.is_null() {
        return -1;
    }
    let tsv = unsafe { cstr(tsv) };
    guard_int(|| {
        let Some(tsv) = tsv else { return -1 };
        let memory = unsafe { &mut *memory };
        memory.inner.import_tsv(&tsv) as i32
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    unsafe fn call_str(f: impl FnOnce() -> *mut c_char) -> Option<String> {
        let p = f();
        if p.is_null() {
            return None;
        }
        let s = unsafe { CStr::from_ptr(p) }.to_str().ok()?.to_string();
        unsafe { inputflow_free_string(p) };
        Some(s)
    }

    #[test]
    fn end_to_end_via_c_abi() {
        let session = unsafe { inputflow_new(c"pinyin".as_ptr()) };
        assert!(!session.is_null());
        unsafe {
            for ch in ["n", "i", "h", "a", "o"] {
                let c = CString::new(ch).unwrap();
                assert_eq!(inputflow_feed(session, c.as_ptr()), 1);
            }
            let json = call_str(|| inputflow_composition_json(session)).unwrap();
            assert!(json.contains("\"preedit\":\"ni hao\""), "{json}");
            assert!(json.contains("你好"), "{json}");
            let text = call_str(|| inputflow_select(session, 0)).unwrap();
            assert_eq!(text, "你好");
            let json = call_str(|| inputflow_composition_json(session)).unwrap();
            assert!(json.contains("\"raw\":\"\""), "{json}");
            inputflow_free(session);
        }
    }

    #[test]
    fn null_and_bad_args_are_safe() {
        unsafe {
            assert!(inputflow_composition_json(std::ptr::null_mut()).is_null());
            assert_eq!(inputflow_feed(std::ptr::null_mut(), c"a".as_ptr()), 0);
            assert!(inputflow_select(std::ptr::null_mut(), 0).is_null());
            assert_eq!(inputflow_set_mode(std::ptr::null_mut(), c"en".as_ptr()), 0);
        }
    }

    #[test]
    fn mode_switch_and_user_tsv_roundtrip() {
        let session = unsafe { inputflow_new(c"en".as_ptr()) };
        unsafe {
            let m = call_str(|| inputflow_mode(session)).unwrap();
            assert_eq!(m, "en");
            assert_eq!(inputflow_set_mode(session, c"flypy".as_ptr()), 1);
            assert_eq!(call_str(|| inputflow_mode(session)).unwrap(), "flypy");
            assert_eq!(inputflow_user_import(session, c"你好\t3\n".as_ptr()), 1);
            let tsv = call_str(|| inputflow_user_export(session)).unwrap();
            assert_eq!(tsv, "你好\t3\n");
            inputflow_free(session);
        }
    }

    #[test]
    fn traditional_toggle_via_c_abi() {
        let session = unsafe { inputflow_new(c"pinyin".as_ptr()) };
        unsafe {
            assert_eq!(inputflow_traditional(session), 0);
            assert_eq!(inputflow_set_traditional(session, 1), 1);
            assert_eq!(inputflow_traditional(session), 1);
            for ch in ["x", "u", "e", "x", "i"] {
                let c = CString::new(ch).unwrap();
                inputflow_feed(session, c.as_ptr());
            }
            let json = call_str(|| inputflow_composition_json(session)).unwrap();
            assert!(json.contains("學習"), "{json}");
            inputflow_free(session);
        }
    }

    #[test]
    fn backup_roundtrip_via_c_abi() {
        let a = unsafe { inputflow_new(c"pinyin".as_ptr()) };
        let b = unsafe { inputflow_new(c"pinyin".as_ptr()) };
        unsafe {
            assert_eq!(inputflow_user_import(a, c"你好\t3\n".as_ptr()), 1);
            let pack = call_str(|| inputflow_backup_export(a)).unwrap();
            assert!(pack.starts_with("#IFBAK1"), "{pack}");

            let c_pack = CString::new(pack).unwrap();
            assert_eq!(inputflow_backup_import(b, c_pack.as_ptr(), 0), 1);
            assert_eq!(call_str(|| inputflow_user_export(b)).unwrap(), "你好\t3\n");

            assert_eq!(inputflow_backup_import(b, c"坏包".as_ptr(), 0), -1);
            assert_eq!(
                inputflow_backup_import(std::ptr::null_mut(), c_pack.as_ptr(), 0),
                -1
            );
            inputflow_free(a);
            inputflow_free(b);
        }
    }

    #[test]
    fn version_is_not_null() {
        let p = inputflow_version();
        assert!(!p.is_null());
        let v = unsafe { CStr::from_ptr(p) }.to_str().unwrap();
        assert!(!v.is_empty());
    }

    #[test]
    fn ai_catalog_and_recommend_json() {
        let cat = unsafe { call_str(|| inputflow_ai_catalog_json()) }.unwrap();
        assert!(cat.contains("\"id\":\"whisper-base\""), "{cat}");

        let rec = unsafe { call_str(|| inputflow_ai_recommend_json(16 * 1024)) }.unwrap();
        assert!(rec.contains("\"kind\":\"speech\""), "{rec}");
        assert!(rec.contains("\"level\":\"suggested\""), "{rec}");
    }

    #[test]
    fn app_mode_memory_via_c_abi() {
        let mem = inputflow_app_mode_new();
        assert!(!mem.is_null());
        unsafe {
            // 手动切到英文（强信号）→ 判英文；换应用 → 不干预
            assert_eq!(
                inputflow_app_mode_observe(mem, c"com.apple.Terminal".as_ptr(), 0, 1, 1_000),
                1
            );
            assert_eq!(
                inputflow_app_mode_decide(mem, c"com.apple.Terminal".as_ptr(), 1_000),
                0
            );
            assert_eq!(
                inputflow_app_mode_decide(mem, c"com.other.app".as_ptr(), 1_000),
                -1
            );

            // 非法应用 id 被忽略
            assert_eq!(
                inputflow_app_mode_observe(mem, c"".as_ptr(), 1, 1, 1_000),
                0
            );
            assert_eq!(
                inputflow_app_mode_observe(mem, c"a\tb".as_ptr(), 1, 1, 1_000),
                0
            );

            // 导出 → 导入另一个实例 → 判定一致
            let tsv = call_str(|| inputflow_app_mode_export(mem)).unwrap();
            let other = inputflow_app_mode_new();
            let c_tsv = CString::new(tsv).unwrap();
            assert_eq!(inputflow_app_mode_import(other, c_tsv.as_ptr()), 1);
            assert_eq!(
                inputflow_app_mode_decide(other, c"com.apple.Terminal".as_ptr(), 1_000),
                0
            );

            // 忘记后不再判定
            assert_eq!(
                inputflow_app_mode_forget(other, c"com.apple.Terminal".as_ptr()),
                1
            );
            assert_eq!(
                inputflow_app_mode_decide(other, c"com.apple.Terminal".as_ptr(), 1_000),
                -1
            );
            inputflow_app_mode_free(other);
            inputflow_app_mode_free(mem);
        }
    }

    #[test]
    fn app_mode_null_and_bad_args_are_safe() {
        unsafe {
            assert_eq!(
                inputflow_app_mode_observe(std::ptr::null_mut(), c"a".as_ptr(), 1, 1, 0),
                0
            );
            assert_eq!(
                inputflow_app_mode_decide(std::ptr::null_mut(), c"a".as_ptr(), 0),
                -1
            );
            assert_eq!(
                inputflow_app_mode_forget(std::ptr::null_mut(), c"a".as_ptr()),
                0
            );
            assert!(inputflow_app_mode_export(std::ptr::null_mut()).is_null());
            assert_eq!(
                inputflow_app_mode_import(std::ptr::null_mut(), c"x".as_ptr()),
                -1
            );
            inputflow_app_mode_free(std::ptr::null_mut());
        }
    }

    #[test]
    fn evolution_via_c_abi() {
        let mem = inputflow_evolution_new();
        assert!(!mem.is_null());
        unsafe {
            let word = CString::new("先").unwrap();
            let lex = CString::new("优先").unwrap();
            let app = CString::new("com.apple.Notes").unwrap();
            let cands = CString::new(
                r#"[{"text":"现","score":10.5},{"text":"先","score":9.0}]"#,
            )
            .unwrap();

            // 一次奖励不足置信
            inputflow_evolution_reward(mem, word.as_ptr(), lex.as_ptr(), app.as_ptr(), 10, 100, 1_000);
            let out = call_str(|| {
                inputflow_evolution_adjust_json(mem, cands.as_ptr(), lex.as_ptr(), app.as_ptr(), 10, 1_100)
            })
            .unwrap();
            assert!(out.starts_with("\"text\":\"现\"") || out.contains("\"text\":\"现\""), "{out}");

            // 两次奖励后上浮
            inputflow_evolution_reward(mem, word.as_ptr(), lex.as_ptr(), app.as_ptr(), 10, 100, 1_200);
            let out = call_str(|| {
                inputflow_evolution_adjust_json(mem, cands.as_ptr(), lex.as_ptr(), app.as_ptr(), 10, 1_300)
            })
            .unwrap();
            assert!(out.find("\"text\":\"先\"").unwrap() < out.find("\"text\":\"现\"").unwrap(), "{out}");
            assert!(out.contains("\"delta\""), "{out}");

            // 决策轨道
            let trail = call_str(|| {
                inputflow_evolution_explain_json(mem, word.as_ptr(), lex.as_ptr(), app.as_ptr(), 10, 1_400)
            })
            .unwrap();
            assert!(trail.contains("\"feature\":\"lex:"), "{trail}");

            // 导出/导入回环
            let tsv = call_str(|| inputflow_evolution_export(mem)).unwrap();
            let other = inputflow_evolution_new();
            let c_tsv = CString::new(tsv).unwrap();
            assert!(inputflow_evolution_import(other, c_tsv.as_ptr()) >= 1);
            inputflow_evolution_forget_all(other);
            inputflow_evolution_free(other);
            inputflow_evolution_free(mem);
        }
    }

    #[test]
    fn evolution_null_args_are_safe() {
        unsafe {
            let w = c"先".as_ptr();
            assert_eq!(
                inputflow_evolution_reward(std::ptr::null_mut(), w, w, w, 0, 100, 0),
                0
            );
            assert!(inputflow_evolution_adjust_json(std::ptr::null_mut(), w, w, w, 0, 0).is_null());
            assert!(inputflow_evolution_explain_json(std::ptr::null_mut(), w, w, w, 0, 0).is_null());
            assert!(inputflow_evolution_export(std::ptr::null_mut()).is_null());
            assert_eq!(inputflow_evolution_import(std::ptr::null_mut(), w), -1);
            inputflow_evolution_free(std::ptr::null_mut());
            inputflow_evolution_forget_all(std::ptr::null_mut());
        }
    }

    #[test]
    fn plugin_scan_via_c_abi() {
        let root = std::env::temp_dir().join(format!("iffi-plugin-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let pack = root.join("skin-x");
        std::fs::create_dir_all(&pack).unwrap();
        std::fs::write(
            pack.join("plugin.json"),
            r#"{"id":"skin-x","name":"X","version":"1.0.0","kind":"skin","permissions":[]}"#,
        )
        .unwrap();
        std::fs::write(pack.join("theme.json"), "{}").unwrap();

        let c_dir = CString::new(root.to_str().unwrap()).unwrap();
        let json = unsafe { call_str(|| inputflow_plugin_scan_json(c_dir.as_ptr())) }.unwrap();
        assert!(json.contains("\"id\":\"skin-x\""), "{json}");
        assert!(json.contains("\"errors\":[]"), "{json}");

        let c_missing = CString::new("/nonexistent-inputflow-plugins").unwrap();
        let empty = unsafe { call_str(|| inputflow_plugin_scan_json(c_missing.as_ptr())) }.unwrap();
        assert!(empty.contains("\"packs\":[]"), "{empty}");
        let _ = std::fs::remove_dir_all(&root);
    }
}
