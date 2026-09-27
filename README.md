<div align="center">

<img src="docs/assets/logo.png" width="110" alt="InputFlow">

# InputFlow

**隐私优先的跨平台输入法 — 纯本地引擎 · 零服务器 · 零遥测**

打字这件事不需要交给云:引擎、词典、学习全部在你设备上跑;跨端同步走局域网 P2P 端到端加密,没有账号,没有"匿名上报"。

[![License](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B%20Universal-black.svg)](#平台与当前状态)
[![Kernel](https://img.shields.io/badge/Rust%20内核-13%20crates%20·%20零第三方依赖-orange.svg)](#架构)
[![Tests](https://img.shields.io/badge/内核测试-206%20项全绿-1fa971.svg)](#快速上手)

[快速上手](#快速上手) · [核心能力](#核心能力) · [定位说明](#定位说明) · [使用指南](#使用指南) · [当前边界](#当前边界)

</div>

---

> **三个承诺**
>
> 🔒 **你的按键永远不离开你的设备** —— 引擎、词典、学习全部本机运行,安装包可断网使用
> 🙈 **零遥测、零云 API** —— 没有"匿名上报",没有"联网纠错",本地 AI 模型由你显式下载
> 🔍 **一切可审计** —— AGPL-3.0 开源,Rust 内核零第三方依赖,插件是数据不是代码

## 这是什么

输入法是你在每台设备上用得最多、也最敏感的软件——你打的每一个字都经过它。市面上绝大多数输入法把按键、词频、习惯送上云端换"智能";InputFlow 把方向反过来:**所有智能都在本地产生**,云端一个字节都拿不到。

它首先是一个专业输入引擎:Rust 写的 13 个纯逻辑 crate,全拼 / 双拼 / 英文 / 日语罗马字,Viterbi 整句转换,20 万词条,206 项内核单元测试全绿。它也会学你:按应用记忆中英切换(终端自动英文、微信自动中文)、用户词频与短语学习,这些统计模型不到 1 MB,只存在本机。

它不装云,但不排斥 AI:端上语音听写、Gemma / Qwen / Whisper 小模型、同声传译,都是你**显式下载、本机运行、可随时删除**的可选项——不支持端上就禁用,绝不回退云端。

## 核心能力

- **专业输入引擎** — 全拼(20 万词条 + Viterbi 整句 + 前缀补全)· 双拼×3(小鹤 / 微软 / 自然码)· 英文(2 万词 + 词频)· 日语罗马字;中英混输、表情模式(`aa`)、符号输入(`u` 前缀)、简繁转换(OpenCC 词表)
- **按应用记忆中/英** — 本地统计模型学习你的切换习惯:Shift 一按即学,终端自动英文、微信自动中文
- **本地 AI 增强(可选,零云 API)** — L0 统计重排(默认开启,< 1 MB)· L1 端上语音边说边落字 · L2 小模型一键下载(sha256 校验,本机运行)· 同声传译(llama.cpp 独立进程,仅 127.0.0.1 回环)
- **有生命的桌宠** — emoji 兜底 10 形象 + VRM 3D 渲染器(跟随鼠标注视 / 眨眼 / 弹簧骨物理),支持导入 VRoid Studio 自捏角色;点击即中英切换,跨屏跟随
- **插件 = 数据包** — 皮肤 / 桌宠 / 词典,声明式零代码执行,权限白名单制,装包即放目录;无在线市场、无自动更新、无可执行代码
- **权限中心** — 全部敏感能力集中展示:碰什么数据、存在哪、怎么删,关闭即清空

桌宠不是贴图:它是**皮肤资产 + 渲染器**([ADR-0007](docs/adr/0007-desktop-pet-renderers.md))——emoji 兜底零下载,VRM 3D 渲染器本地离线运行(WKWebView + three.js + three-vrm),输入焦点在哪块屏幕就在哪块屏幕互动;气泡只报本机任务,**永不承载付款与营销**([ADR-0006](docs/adr/0006-notifications-and-stats.md))。
- **零内容统计** — 速度、纠错、节省击键、最长发呆、卡路里——只计次与秒,绝不记录任何按键内容
- **局域网 P2P 同步(默认关闭)** — 设备间扫码配对(Ed25519 + 一次性配对码 + 6 位校验码防中间人),mDNS 发现、端到端加密,没有服务器没有账号;用户词与剪切板历史 ChaCha20-Poly1305 加密落盘,密钥在系统钥匙串

**输入方案与状态**

| 方案 | 状态 |
|---|---|
| 全拼(20 万词条 + Viterbi 整句 + 前缀补全)· 双拼(小鹤 / 微软 / 自然码) | ✅ |
| 英文(2 万词前缀补全 + 词频)· 日语(罗马字 → 假名) | ✅ |
| 中英混输(候选融合英文,大写即英文意图)· 简繁转换(OpenCC 词表) | ✅ |
| 表情模式(连按 `aa`)· 符号输入(`u` 前缀) | ✅ |
| 日语(假名 → 汉字,JMdict + Viterbi) | ⏳ M2 |

## 快速上手

```bash
cargo test                                  # 内核 206 项测试,全绿是合并底线

# macOS 输入法(Universal:Intel → M 系列,macOS 13+)
./platforms/macos/build.sh                  # 构建自动选用可用签名身份
./platforms/macos/install.sh                # 安装到 ~/Library/Input Methods
```

启用:**系统设置 → 键盘 → 输入法 → + → 中文(简体)→ InputFlow**
(macOS 26 仅收录有效签名;ad-hoc 构建需注销重登录或先配置签名身份)

发布分发:`./platforms/macos/dist.sh`(签名 → Hardened Runtime → 公证 → DMG → staple);签名三级降级如实标注产物,绝不假装可分发。

做皮肤 / 桌宠包不需要会写代码:

```bash
cargo run -p xtask -- plugin new --kind skin --id skin-mine --name 我的皮肤
cargo run -p xtask -- plugin check plugins/skin-mine
```

## 平台与当前状态

| 平台 | 集成 | 状态 |
|---|---|---|
| macOS | InputMethodKit + Liquid Glass 候选窗 | 🚧 M1(日常可用的主战场) |
| Windows / Linux | TSF / Fcitx5 | ⏳ M3 |
| Android / iOS | IMS+JNI / 键盘扩展(无需 Full Access) | ⏳ M4 |
| HarmonyOS NEXT | IME Kit + NAPI | ⏳ M5 |

## 定位说明

**InputFlow 不是 Flow,也不走 Flow 家族的业务线**——它是芭乐派产品矩阵**第三层:Studio 套件**的周边产品,解决的是 AI 时代的输入与隐私输入:当越来越多文字经由 AI 生成与处理,输入法这个最敏感的入口更不该把数据交给云。矩阵的分层是:

- **OpenFlow = 入口层**:TIPS all-in-one,让一人团队(OPC)与中小团队低门槛完成数字化 + AI 化。
- **Flow 家族 = 进阶层**:MFlow / inFlow / UserLoop / PayFlow / LearnFlow / WebsFlow 按需进阶,各自深耕一个业务场景。
- **Studio 套件 = 本地工具层**:InputFlow、ThirdC(知识工作台)、V2HTML(视频⇄内容引擎)、ZeroZen(广告净化)等,偏本地工具、吸引更多用户,长期方向是**作为工作台打通所有 Flow 产品**。

与 OpenFlow 矩阵是**松耦合**:InputFlow 完全独立运行,不依赖也不对接任何 Flow 产品即可完整使用;共享设计契约(玻璃候选窗、同源设计令牌),未来作为矩阵在输入侧的常驻入口。

## 使用指南

完整使用指南(安装与启用 / 输入方案与快捷键 / 按应用记忆与统计 / 本地 AI 下载与开关 / 插件制作)见 [docs/USAGE-GUIDE.md](docs/USAGE-GUIDE.md)。
设计文档:[架构](docs/architecture.md) · [威胁模型](docs/threat-model.md) · [同步协议](docs/sync-protocol.md) · [ADR 决策记录](docs/adr/)。

## 当前边界

- **目前只有 macOS 可用**(macOS 13+,M1 里程碑进行中);Windows / Linux / 移动端 / 鸿蒙按 M3–M5 排期,未落地
- **日语只有罗马字 → 假名**:假名 → 汉字(JMdict + Viterbi)在 M2,尚不可用
- **跨端同步传输未完成**:协议与合并内核(HLC + LWW/CRDT)已实现并有测试,QUIC/TLS 传输层与配对 UI 在 M3;当前版本同步默认关闭
- **不进输入法商店、无云词库**:安装靠 DMG / 脚本,词库更新随版本发布;这是隐私承诺的代价,也是选择

## License

AGPL-3.0-only(见 [LICENSE](LICENSE))。内置词库数据来源与许可见
[dict](crates/dict/data/SOURCES.md) / [en](crates/en/data/SOURCES.md) / [zhconv](crates/zhconv/data/SOURCES.md)(含 GPL-3.0 / MIT / Apache-2.0 数据)。

---

<div align="center">

**如果它让你的打字更顺手、更安心,点一个 ⭐ 让更多人看到**

</div>
