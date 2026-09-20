//! InputFlow 构建工具（零依赖）。
//!
//! ```text
//! xtask dict build <input.tsv> -o <output.ifd> [--with-base]
//! xtask dict import-rime <dict.yaml> -o <output.ifd> [--with-base]
//! xtask dict import-rime-multi -o <output.ifd> [--tsv out.tsv] [--max-entries N] \
//!     <file.yaml[:scale]> [<file.yaml[:scale]> ...]
//! xtask dict stats <file.ifd|file.tsv>
//! ```

use std::process::ExitCode;

use inputflow_dict::Dictionary;
use inputflow_dict::import::{ImportReport, parse_rime_dict, parse_rime_dicts, parse_tsv};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("错误: {e}");
            eprintln!();
            usage();
            ExitCode::FAILURE
        }
    }
}

fn run(args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str) {
        Some("dict") => dict_cmd(&args[1..]),
        Some("-h") | Some("--help") => {
            usage();
            Ok(())
        }
        Some(other) => Err(format!("未知命令: {other}")),
        None => {
            usage();
            Ok(())
        }
    }
}

fn dict_cmd(args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str) {
        Some("build") => {
            let (input, output, with_base) = parse_io(&args[1..])?;
            let src = read(&input)?;
            let (mut dict, report) = parse_tsv(&src);
            print_report("TSV", &input, &report);
            if with_base {
                let base = Dictionary::embedded();
                dict.merge(&base);
                println!("已合并内置基础词典：+{} 词条", base.entry_count());
            }
            write_ifd(&dict, &output)
        }
        Some("import-rime") => {
            let (input, output, with_base) = parse_io(&args[1..])?;
            let src = read(&input)?;
            let (mut dict, report) = parse_rime_dict(&src);
            print_report("Rime", &input, &report);
            if with_base {
                let base = Dictionary::embedded();
                dict.merge(&base);
                println!("已合并内置基础词典：+{} 词条", base.entry_count());
            }
            write_ifd(&dict, &output)
        }
        Some("import-rime-multi") => import_rime_multi(&args[1..]),
        Some("stats") => {
            let Some(path) = args.get(1) else {
                return Err("stats 需要文件路径".into());
            };
            let bytes = std::fs::read(path).map_err(|e| format!("读取 {path} 失败: {e}"))?;
            if bytes.starts_with(b"IFD1") {
                let dict =
                    Dictionary::from_bytes(&bytes).map_err(|e| format!("解析 {path} 失败: {e}"))?;
                println!("{path}: IFD1 词典");
                println!("  key 数: {}", dict.key_count());
                println!("  词条数: {}", dict.entry_count());
                println!("  文件大小: {} 字节", bytes.len());
            } else {
                let src = String::from_utf8(bytes).map_err(|_| "不是 UTF-8 文本".to_string())?;
                let (dict, report) = parse_tsv(&src);
                print_report("TSV", path, &report);
                println!("  key 数: {}", dict.key_count());
                println!("  词条数: {}", dict.entry_count());
            }
            Ok(())
        }
        Some(other) => Err(format!("未知 dict 子命令: {other}")),
        None => Err("dict 需要子命令（build/import-rime/import-rime-multi/stats）".into()),
    }
}

fn import_rime_multi(args: &[String]) -> Result<(), String> {
    let mut inputs: Vec<(String, f64)> = Vec::new();
    let mut output = None;
    let mut tsv = None;
    let mut max_entries = 0usize;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-o" | "--output" => {
                i += 1;
                output = Some(args.get(i).ok_or("--output 需要一个路径")?.clone());
            }
            "--tsv" => {
                i += 1;
                tsv = Some(args.get(i).ok_or("--tsv 需要一个路径")?.clone());
            }
            "--max-entries" => {
                i += 1;
                max_entries = args
                    .get(i)
                    .and_then(|v| v.parse().ok())
                    .ok_or("--max-entries 需要一个整数")?;
            }
            other => {
                let (path, scale) = match other.rsplit_once(':') {
                    Some((p, s)) => match s.parse::<f64>() {
                        Ok(v) => (p.to_string(), v),
                        Err(_) => (other.to_string(), 1.0),
                    },
                    None => (other.to_string(), 1.0),
                };
                inputs.push((path, scale));
            }
        }
        i += 1;
    }
    let output = output.ok_or("需要 -o 输出文件")?;
    if inputs.is_empty() {
        return Err("需要至少一个 Rime 词库文件".into());
    }
    let mut sources: Vec<(String, String, f64)> = Vec::with_capacity(inputs.len());
    for (path, scale) in &inputs {
        sources.push((path.clone(), read(path)?, *scale));
    }
    let (mut dict, report) = parse_rime_dicts(&sources);
    print_report("Rime 合并", &format!("{} 个来源", sources.len()), &report);
    for (path, scale) in &inputs {
        println!("  - {path} (×{scale})");
    }
    if max_entries > 0 {
        let (singles, multi) = dict.prune(max_entries);
        println!("剪枝: 保留单音节 {singles} / 多音节 {multi}");
    }
    write_ifd(&dict, &output)?;
    if let Some(path) = tsv {
        std::fs::write(&path, dict.to_tsv()).map_err(|e| format!("写入 {path} 失败: {e}"))?;
        println!("已写出 {path}: {} 词条", dict.entry_count());
    }
    Ok(())
}

fn parse_io(args: &[String]) -> Result<(String, String, bool), String> {
    let mut input = None;
    let mut output = None;
    let mut with_base = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-o" | "--output" => {
                i += 1;
                output = Some(
                    args.get(i)
                        .ok_or_else(|| "-o 需要一个输出路径".to_string())?
                        .clone(),
                );
            }
            "--with-base" => with_base = true,
            other if input.is_none() && !other.starts_with('-') => input = Some(other.to_string()),
            other => return Err(format!("无法识别的参数: {other}")),
        }
        i += 1;
    }
    match (input, output) {
        (Some(i), Some(o)) => Ok((i, o, with_base)),
        _ => Err("需要输入文件与 -o 输出文件".into()),
    }
}

fn read(path: &str) -> Result<String, String> {
    std::fs::read_to_string(path).map_err(|e| format!("读取 {path} 失败: {e}"))
}

fn print_report(kind: &str, path: &str, report: &ImportReport) {
    println!("{kind} 导入 {path}");
    println!(
        "  总计 {} 行，导入 {} 条，跳过 {} 条",
        report.total, report.imported, report.skipped
    );
    for e in &report.errors {
        println!("  ! {e}");
    }
}

fn write_ifd(dict: &Dictionary, output: &str) -> Result<(), String> {
    let bytes = dict.to_bytes();
    std::fs::write(output, &bytes).map_err(|e| format!("写入 {output} 失败: {e}"))?;
    println!(
        "已写出 {output}: {} key / {} 词条 / {} 字节",
        dict.key_count(),
        dict.entry_count(),
        bytes.len()
    );
    Ok(())
}

fn usage() {
    eprintln!(
        "用法:\n  \
         xtask dict build <input.tsv> -o <output.ifd> [--with-base]\n  \
         xtask dict import-rime <dict.yaml> -o <output.ifd> [--with-base]\n  \
         xtask dict import-rime-multi -o <output.ifd> [--tsv out.tsv] [--max-entries N] \\\n      \
             <file.yaml[:scale]> [<file.yaml[:scale]> ...]\n  \
         xtask dict stats <file.ifd|file.tsv>"
    );
}
