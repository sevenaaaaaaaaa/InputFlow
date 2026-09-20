//! IFD1 二进制编解码：varint + 长度前缀字符串。

use crate::DictError;

pub const MAGIC: [u8; 4] = *b"IFD1";

pub fn write_varint(out: &mut Vec<u8>, mut v: u64) {
    loop {
        let mut byte = (v & 0x7f) as u8;
        v >>= 7;
        if v != 0 {
            byte |= 0x80;
        }
        out.push(byte);
        if v == 0 {
            break;
        }
    }
}

pub fn read_varint(b: &[u8], pos: &mut usize) -> Result<u64, DictError> {
    let mut v: u64 = 0;
    let mut shift = 0;
    loop {
        let Some(&byte) = b.get(*pos) else {
            return Err(DictError::Truncated);
        };
        *pos += 1;
        v |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Ok(v);
        }
        shift += 7;
        if shift > 63 {
            return Err(DictError::Overflow);
        }
    }
}

pub fn write_str(out: &mut Vec<u8>, s: &str) {
    write_varint(out, s.len() as u64);
    out.extend_from_slice(s.as_bytes());
}

pub fn read_str(b: &[u8], pos: &mut usize) -> Result<String, DictError> {
    let len = read_varint(b, pos)? as usize;
    let end = pos.checked_add(len).ok_or(DictError::Overflow)?;
    let slice = b.get(*pos..end).ok_or(DictError::Truncated)?;
    *pos = end;
    String::from_utf8(slice.to_vec()).map_err(|_| DictError::InvalidUtf8)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn varint_roundtrip() {
        for v in [0u64, 1, 127, 128, 300, 16384, u32::MAX as u64, u64::MAX] {
            let mut b = Vec::new();
            write_varint(&mut b, v);
            let mut pos = 0;
            assert_eq!(read_varint(&b, &mut pos).unwrap(), v);
            assert_eq!(pos, b.len());
        }
    }

    #[test]
    fn string_roundtrip() {
        let mut b = Vec::new();
        write_str(&mut b, "ni'hao");
        write_str(&mut b, "你好");
        let mut pos = 0;
        assert_eq!(read_str(&b, &mut pos).unwrap(), "ni'hao");
        assert_eq!(read_str(&b, &mut pos).unwrap(), "你好");
        assert_eq!(pos, b.len());
    }

    #[test]
    fn truncated_detected() {
        let mut pos = 0;
        assert_eq!(read_varint(&[0x80], &mut pos), Err(DictError::Truncated));
        let mut pos = 0;
        assert_eq!(read_str(&[5, b'a'], &mut pos), Err(DictError::Truncated));
    }
}
