# InputFlow for macOS（M1）

InputMethodKit 外壳 + Rust 内核静态库；候选窗在 macOS 26+ 使用系统原生 Liquid Glass，
旧系统回退 `NSVisualEffectView`。**无网络代码**：既没有网络权限声明，也不链接任何网络库
（AI 模型下载是唯一例外，只在用户点击下载时建立 HTTPS 连接）。

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
| 标点（未组合时） | 中文模式自动转全角；代码编辑器/终端按应用画像保持半角 |
| 中英混输 | 拼音里直接混英文：`hello`→直接出 `hello`；大写开头按英文意图处理 |
| 连按两下 `a`（浏览器） | 进入网址模式：按键直通系统，Esc / 回车退出 |
| 连按两下 `a`（聊天工具） | 进入表情模式（斗图）：空格选表情，拼音可过滤，Esc 退出 |
| 输入法菜单 | 切换 拼音 / 小鹤双拼 / 微软双拼 / 自然码 / English / 日本語 |
| 输入法菜单 | 桌宠模式（可拖动玻璃小猫，随输入状态切换表情） |
| 输入法菜单 | 剪切板历史（最近 8 条直接上屏；开启/关闭记录） |
| 输入法菜单 | AI 增强…（内置统计模型状态、小模型下载/校验/启停） |

## 智能交互（无需配置）

- **应用感知**：前台 App 自动识别，代码编辑器/终端标点保持半角，聊天/浏览器用中文标点；
- **双 `a` 手势**：浏览器进入网址模式（字母、标点全部直通，不经过输入法），
  聊天工具进入表情模式（内置精选表情，`daku`→😭、`zan`→👍，空格上屏）；
- **桌宠模式**：菜单一键开关，位置记忆；输入时表情联动（发呆 🐱 / 思考 🙀 / 开心 😻）；
- **光标跟随**：候选窗优先用 `firstRect` 定位，屏幕边缘自动翻转，多屏跟随光标所在屏。

## 用户数据（加密持久化）

- 用户词 + 上下词二元组 + 剪切板历史统一存
  `~/Library/Application Support/InputFlow/userdata.enc`（0600）；
- 密钥 256-bit 随机生成，存系统钥匙串（service `dev.inputflow.inputmethod`），
  钥匙串不可用时本次运行不落盘，绝不把密钥写到数据文件旁边；
- 格式：`IFUE` + 版本 + ChaCha20-Poly1305（头部作为 AAD），原子写入；
  文件损坏时隔离为 `userdata.enc.corrupt` 并按空数据继续；
- 剪切板历史**默认关闭**：跳过密码管理器标记的 Concealed/Transient 内容，
  上限 200 条 / 单条 100 KB，可一键清空；
- 校验：`grep -a` 搜索文件应无明文；`ls -l` 应为 `-rw-------`。

```bash
./uninstall.sh --purge   # 同时删除数据目录与钥匙串密钥
```

## 调试命令

```bash
BIN="$HOME/Library/Input Methods/InputFlow.app/Contents/MacOS/InputFlow"
"$BIN" --store-smoke       # 加密存储自检（临时文件，不触碰真实数据）
"$BIN" --store-info        # 钥匙串可用性 + 已加载数据量
"$BIN" --clipboard-smoke   # 剪切板监控自检（真实路径，写入一条测试数据）
"$BIN" --ai-dump           # 模型目录 + 按内存推荐
"$BIN" --clipboard-window  # 直接打开剪切板历史窗
"$BIN" --pet-window        # 直接显示桌宠（并做一次开心动画）
"$BIN" --ai-settings       # 直接打开 AI 增强窗
```

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

- `Sources/Engine.swift`：C ABI 封装 + JSON 解码（组合态、候选、AI 目录）；
- `Sources/InputController.swift`：按键翻译、预编辑串、模式菜单、Shift 切换、剪切板上屏、双 `a` 手势；
- `Sources/AppProfile.swift`：应用画像（代码/浏览器/聊天）与标点策略；
- `Sources/PetWindow.swift`：桌宠（状态表情、拖动、位置记忆）；
- `Sources/CandidateWindow.swift`：候选窗（NSGlassEffectView / NSVisualEffectView 回退）；
- `Sources/EncryptedStore.swift`：`userdata.enc` 容器（钥匙串密钥、ChaCha20-Poly1305、原子写）；
- `Sources/ClipboardMonitor.swift` / `ClipboardWindow.swift`：剪切板监控与历史窗；
- `Sources/AIModelStore.swift` / `SettingsWindow.swift`：模型下载/校验与 AI 增强窗；
- 目标版本默认 `arm64-apple-macos13.0`，可用 `MACOSX_DEPLOYMENT_TARGET=14.0 ./build.sh` 覆盖；
  Intel 机器上脚本自动使用 `x86_64`（暂不产出 universal 包）。

## 已知限制（M1）

- 数字保持半角；emoji 未接入；
- 跨设备同步（用户词/剪切板）在 M3；
- 双拼键位表以 Rime 官方 schema 为准，仍建议对照输入验证（见 `crates/pinyin/src/scheme.rs` 注释）。
