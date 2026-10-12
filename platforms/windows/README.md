# Windows TSF 构建

## 架构

```
liana.h (C ABI) ← textservice.cpp (COM/TSF 协议翻译) ← TSF (ctfmon.exe 加载)
     ↑
libliana_ffi.lib（Rust 内核静态链接，x86_64-pc-windows-msvc）
```

## 状态（截至 v0.2.0）

| 部分 | 状态 |
|---|---|
| Rust 内核 x86_64-pc-windows-msvc 静态库 | ✅ 本机已验证（cargo rustc --crate-type staticlib） |
| COM 骨架（IUnknown/类厂/DllGetClassObject） | ✅ 代码完整 |
| 按键 sink → 内核 feed | ✅ 代码完整 |
| 组合文本上屏（ITfComposition + edit session） | ⚠️ TODO，需按微软 keystroke TSF 样板补全 |
| 候选窗（ITfCandidateListUIElement） | ⚠️ TODO |
| DllRegisterServer 的 CTF/TIP 注册表写入 | ⚠️ TODO |
| MSVC 实机编译与 regsvr32 注册 | ⚠️ 需 Windows 机器 |

## 构建（在 Windows 上）

```cmd
:: x64 Native Tools Command Prompt
cd platforms\windows
build.cmd
regsvr32 build\liana_tsf.dll   :: 管理员
```

## 参考

- 微软官方样例：[TextService sample（keystroke TSF）](https://github.com/microsoft/Windows-classic-samples/tree/master/Samples/TextService)
- TSF 概览：Text Services Framework 文档
- 组合文本：ITfContextComposition / ITfCompositionSink / ITfEditSession

## 已知决策

- 用 C++ 写 COM 壳（而不是 Rust 手写 COM）：TSF 接口数量多，C++ + ATL 更稳，
  Rust 只做引擎——与 macOS(Swift)/Android(Kotlin)/iOS(Swift)/鸿蒙(ArkTS) 分工一致。
- 内核静态链接而非 cdylib：避免分发额外 DLL 与加载路径问题。