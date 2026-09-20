# InputFlow

**隐私优先的跨平台输入法**：纯本地引擎、零服务器、零遥测，跨端同步走局域网 P2P 端到端加密。

- **不联网也能用**：引擎、词典、学习全部在本机；安装包可断网运行。
- **本地 AI 可选**：内置统计模型（用户词 + 上下词预测）零配置生效；Gemma / Qwen / Whisper 等小模型由你显式下载并在本机运行，无云 API，语音强制端上识别。
- **同步不经过任何服务器**：二维码配对 → 局域网直连（QUIC + TLS 1.3 双向认证），用户词与剪切板只在你的设备之间流动。
- **开源可审计**：AGPL-3.0，无第三方运行时依赖（内核零 crates 依赖）。
- **苹果 Liquid Glass**：macOS/iOS 26+ 使用系统原生玻璃 API，其他平台用同源设计契约近似。

## 输入方案

| 方案 | 状态 |
|---|---|
| 全拼（20 万词条词库 + Viterbi 整句 + 前缀补全） | ✅ M0 |
| 中英混输（拼音候选里融合英文补全，大写即英文意图） | ✅ M1 |
| 双拼（小鹤 / 微软 / 自然码） | ✅ M0 |
| 英文（2 万词前缀补全 + 词频） | ✅ M0 |
| 日语（罗马字 → 假名） | ✅ M0（假名） |
| 表情模式（连按 `aa`，拼音关键词过滤） | ✅ M1 |
| 日语（假名 → 汉字，Viterbi + JMdict） | ⏳ M2 |

## 本地 AI 增强（可选，零云 API）

| 层级 | 内容 | 默认 |
|---|---|---|
| L0 统计模型 | 用户词频 + 历史二元组重排（< 1 MB，零下载、随输入学习） | 开启 |
| L1 端上语音 | 系统本地语音识别（强制端上；不支持则禁用，绝不回退云端） | 关闭 |
| L2 小模型 | Gemma 3 / Qwen2.5 / Qwen3 / Whisper 一键下载（sha256 校验，本地运行） | 关闭 |

模型按本机内存自动推荐（≤ 12.5% 标「推荐开启」，> 25% 不推荐）。
设置入口：输入法菜单 →「AI 增强…」。设计见 `docs/adr/0004-local-ai-optional-models.md`。

## 平台

| 平台 | 集成方式 | 状态 |
|---|---|---|
| macOS | InputMethodKit + NSGlassEffectView | 🚧 M1（加密持久化 + 剪切板历史 + AI 增强） |
| Windows | TSF（windows-rs） | ⏳ M3 |
| Linux | Fcitx5 addon | ⏳ M3 |
| Android | InputMethodService + JNI | ⏳ M4 |
| iOS | 键盘扩展（Rust staticlib，无需 Full Access） | ⏳ M4 |
| HarmonyOS NEXT | IME Kit + NAPI（需华为签名） | ⏳ M5 |

## 目录

```
crates/core     类型与契约（候选、组合态、音节表），零依赖
crates/dict     词典二进制格式 + 文本/Rime 导入器 + 20 万词条主词库
crates/pinyin   全拼/双拼解码（切分 + Viterbi + 前缀补全）与测试
crates/en       英文补全（2 万词）
crates/ja       日语罗马字 → 假名
crates/emoji    表情模式（拼音关键词过滤，零依赖）
crates/ai       本地 AI 模型目录与内存推荐（零依赖）
crates/sync     同步合并内核（LWW/CRDT 纯逻辑，无网络）
crates/engine   会话编排：模式切换、翻页、学习重排
crates/ffi      C ABI + JSON（供各平台前端调用）
platforms/macos 输入法 App（Swift + IMKit + Liquid Glass 候选窗）
xtask           词典构建/导入 CLI
docs/           产品、架构、威胁模型、同步协议、ADR
```

## 快速开始

```bash
cargo test                      # 内核测试
cargo run -p xtask -- dict build crates/dict/data/base-large.tsv -o base.ifd

# macOS 输入法（构建并安装到 ~/Library/Input Methods）
./platforms/macos/build.sh
./platforms/macos/install.sh
```

词典数据的来源与再生成流程见 `crates/dict/data/SOURCES.md`。

## 隐私承诺

1. 内核不发任何网络请求，代码可审计；前端仅提供可选的局域网同步开关（默认关闭）。
2. 按键缓存只在内存，提交后即清；用户词与剪切板历史加密落盘（ChaCha20-Poly1305），密钥在系统钥匙串；剪切板历史默认关闭。
3. 不申请 iOS Full Access 即可完整输入（同步功能除外）。
4. 详见 `docs/threat-model.md`：明确能防什么、不能防什么。

## 许可

AGPL-3.0-only，见 `LICENSE`。内置词库数据来源与许可见
`crates/dict/data/SOURCES.md`、`crates/en/data/SOURCES.md`（含 GPL-3.0 / MIT 数据）。
