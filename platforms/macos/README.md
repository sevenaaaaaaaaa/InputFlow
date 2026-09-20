# InputFlow for macOS（M0 骨架）

InputMethodKit 外壳 + Rust 内核静态库；候选窗在 macOS 26+ 使用系统原生 Liquid Glass，
旧系统回退 `NSVisualEffectView`。**无网络代码**：既没有网络权限声明，也不链接任何网络库。

## 构建与安装

```bash
./build.sh      # cargo 静态库 + swiftc + 手工 bundle + ad-hoc 签名
./install.sh    # 安装到 ~/Library/Input Methods，并准备数据目录
```

`install.sh` 会调用输入法自带的注册命令（`--register-input-source`、`--enable-input-source`），
等价于 Squirrel 的安装流程；这些命令也可以单独手动执行：

```bash
BIN="$HOME/Library/Input Methods/InputFlow.app/Contents/MacOS/InputFlow"
"$BIN" --register-input-source   # 通知系统缓存重建
"$BIN" --enable-input-source     # 在输入法列表中启用
"$BIN" --select-input-source     # 立即切换为当前输入法
"$BIN" --input-source-status     # 查看启用/选中状态
```

首次启用（macOS 对输入法注册有缓存，需要重新登录一次）：

1. 注销并重新登录；
2. 系统设置 → 键盘 → 文字输入 → 输入法 → 编辑… → `+` → 中文（简体）→ **InputFlow**；
3. 用 `Ctrl+Space` 切到 InputFlow。

卸载：`./uninstall.sh`（加 `--purge` 一并删除用户数据）。

## 用法

| 按键 | 行为 |
|---|---|
| 字母 / `'` / `;` | 输入拼音（`;` 为微软双拼的 ing 键） |
| 空格 | 选第一个候选；无候选时不上屏 |
| 数字 `1`-`9` | 选词（配合翻页） |
| `←` `→` / `-` `=` / PageUp/PageDown | 候选翻页 |
| 回车 | 原样上屏当前编码 |
| Esc | 取消当前组合 |
| 单按左 Shift | 中/英切换（不影响正常大写输入） |
| 标点（未组合时） | 中文模式自动转全角：`，。？！；：、（）【】《》“”‘’` 等 |
| 输入法菜单 | 切换 拼音 / 小鹤双拼 / 微软双拼 / 自然码 / English / 日本語 |
| 输入法菜单 | AI 增强…（内置统计模型状态、小模型下载/校验/启停） |

## 本地 AI 增强

- **L0 统计模型**（默认开启）：用户词频 + 历史二元组重排，内存 < 1 MB，零下载；
- **L2 小模型**（默认关闭）：Gemma 3 / Qwen2.5 / Qwen3 / Whisper，按本机内存推荐；
  下载仅在你点击后发生，完成后做 sha256 校验，存放于
  `~/Library/Application Support/InputFlow/models/`，可一键删除；
- 神经模型推理运行时（llama.cpp / whisper.cpp）将在 M2 接入；
- 设计约束见 `docs/adr/0004-local-ai-optional-models.md`。

## 词典

- 内置主词库 20 万词条（单字 4.6 万 + 词语 15.4 万），rime-ice 导入 + 人工校准高频词，
  来源与许可见 `crates/dict/data/SOURCES.md`；
- 外部词典：`~/Library/Application Support/InputFlow/base.ifd`（install.sh 自动安装；重新登录或切换输入法后生效）；
- 从 Rime 词库导入（例如雾凇拼音）：

```bash
cd ../../
cargo run -p xtask -- dict import-rime ~/Downloads/pinyin.dict.yaml \
    -o /tmp/base.ifd --with-base
cp /tmp/base.ifd ~/Library/Application\ Support/InputFlow/base.ifd
```

## 开发说明

- `Sources/Engine.swift`：C ABI 封装 + JSON 解码（组合态、候选）；
- `Sources/InputController.swift`：按键翻译、预编辑串、模式菜单、Shift 切换；
- `Sources/CandidateWindow.swift`：候选窗（NSGlassEffectView / NSVisualEffectView 回退）；
- 目标版本默认 `arm64-apple-macos13.0`，可用 `MACOSX_DEPLOYMENT_TARGET=14.0 ./build.sh` 覆盖；
  Intel 机器上脚本自动使用 `x86_64`（暂不产出 universal 包）。

## 已知限制（M0）

- 用户词只在内存，重启丢失（M1 加密落盘）；
- 数字保持半角；emoji、剪切板历史与跨设备同步未接入（M1/M3）；
- 双拼键位表以 Rime 官方 schema 为准，仍建议对照输入验证（见 `crates/pinyin/src/scheme.rs` 注释）。
