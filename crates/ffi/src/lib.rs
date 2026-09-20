//! C ABI。所有函数内部捕获 panic，绝不跨 FFI 边界展开。
//!
//! 安全契约（与 `include/inputflow.h` 一致）：传入的指针必须指向有效对象；
//! `inputflow_new*` 的字符串参数必须是 NUL 结尾的 UTF-8；返回的 `char*` 必须用
//! `inputflow_free_string` 释放。所有 `unsafe` 导出函数都在此契约下工作。
#![allow(clippy::missing_safety_doc)]

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;

use inputflow_core::Mode;
use inputflow_dict::Dictionary;
use inputflow_engine::Session;

pub struct InputFlowSession {
    inner: Session,
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
}
