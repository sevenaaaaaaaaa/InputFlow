# 架构

## 分层

```
┌──────────────────────────── 平台前端（每端一套 UI） ────────────────────────────┐
│ mac: IMKit+SwiftUI   win: TSF+自绘win32   linux: Fcitx5 addon                    │
│ android: IME Service(Kotlin)   ios: Keyboard Extension(Swift)   harmony: ArkTS   │
└───────────────────────────────┬─────────────────────────────────────────────────┘
                                │ C ABI（crates/ffi，JSON 组合态）
┌───────────────────────────────▼─────────────────────────────────────────────────┐
│ crates/engine  Session：模式切换 / 选词提交 / 翻页 / 用户词重排                    │
│   ├── crates/pinyin   全拼切分 + 双拼解码 + Viterbi 整句                         │
│   ├── crates/en       英文前缀补全                                               │
│   └── crates/ja       罗马字→假名（M2: 假名→汉字）                                │
├──────────────────────────────────────────────────────────────────────────────────┤
│ crates/dict   词典（内存索引 + 二进制格式 + Rime/TSV 导入）                        │
│ crates/core   类型契约 + 音节表 + 用户学习模型                                     │
└──────────────────────────────────────────────────────────────────────────────────┘
        ▲ 可选、默认关闭                          ▲ 纯逻辑、可单测
┌───────┴───────────────┐              ┌─────────┴──────────────┐
│ crates/sync  合并内核  │              │ 本地加密存储（M1 起）    │
│ LWW/CRDT op-log        │              │ 用户词/剪切板/keychain   │
└────────────────────────┘              └────────────────────────┘
```

## 数据流（按键 → 上屏）

```
平台按键 → FFI feed(ch)
  → Session.buffer 追加
  → 对应 Decoder.decode(buffer) → Vec<Candidate>
  → Session 用 UserModel 重排（用户选过的词加权）
  → Composition { raw, preedit, candidates[] } 经 JSON 返回
前端渲染候选窗；用户选词 → FFI select(i) → 返回上屏文本与剩余 buffer
```

- 解码是**纯函数**：`decode(input) -> candidates`，无状态、可单测、可并发。
- 学习与提交是**副作用**：集中在 `Session`，便于审计「什么数据被写到了哪里」。
- 输入缓存只在内存，`clear()` 或提交后立即释放，不落盘、不进日志。

## 词典

- 内存索引：`HashMap<"ni'hao", Vec<Entry>>`，`Entry { word, freq, letters, syls }`。
- 二进制格式 `IFD1`：varint 编码，确定性排序，便于 diff 与校验；大词典可 mmap（M2）。
- 导入：TSV（自研格式）与 Rime `.dict.yaml`（兼容雾凇拼音等现成词库）。
- 用户词：独立 overlay，不进主词典；M1 起用系统钥匙串里的密钥做 ChaCha20-Poly1305 加密落盘。
- 内置基础词典（约 300 条）保证首次可用与测试确定性；正式词库通过 `xtask dict import-rime` 生成。

## 平台集成要点

| 平台 | 关键点 |
|---|---|
| macOS | `IMKServer` + `IMKInputController`；候选窗为无激活 NSPanel，内容用 `NSGlassEffectView`（macOS 26+）或 `NSVisualEffectView` 回退；`LSBackgroundOnly` |
| Windows | TSF Text Service（COM）；候选窗用分层窗口自绘，玻璃近似用 DWM backdrop（Win11 `DWMWA_SYSTEMBACKDROP_TYPE`） |
| Linux | Fcitx5 addon（C++/Rust 混合）；候选窗优先复用 Fcitx5 classic UI 主题，桌宠模式走独立层 |
| Android | `InputMethodService`；Rust `cdylib` 经 JNI；候选 UI 用 Compose，玻璃用 RenderEffect（API 31+） |
| iOS | 键盘扩展（App Extension）；Rust `staticlib`；**不需要** `RequestsOpenAccess`；内存预算 < 40MB |
| HarmonyOS | IME Kit（ArkTS）+ NAPI 调 Rust `so`；需华为签名与上架审核 |

## 设计令牌单一来源

`docs/design-tokens.json` → 生成各端常量（Swift/Kotlin/ArkTS/CSS）。首版手工维护，M1 加生成器 `xtask tokens`。

## 性能预算

| 项 | 预算 |
|---|---|
| 单键处理 | P99 < 8ms（约 8 万词词典，整句 DP 上限 12 音节） |
| 内存常驻 | 桌面 < 60MB，iOS 扩展 < 40MB |
| 冷启动（词典加载） | < 80ms（二进制加载，懒解析） |
| 包体 | macOS < 12MB，移动端 < 20MB（基础词库 + 可选扩展包） |

## 目录约定

- 平台代码只做「按键翻译 + 渲染 + 系统集成」，一切逻辑进 `crates/`。
- `crates/*` 不依赖任何平台 crate；`platforms/*` 不互相依赖。
- 内核 crate 零外部依赖（供应链最小化，也是隐私承诺的一部分）。
