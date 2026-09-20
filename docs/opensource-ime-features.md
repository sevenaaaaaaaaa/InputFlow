# 开源输入法功能调研

> 快照时间：2026-09。来源：各项目官方仓库 / 官网 / README（见文末链接），仅收录公开发布的开源实现。
> 目的：给 InputFlow 的功能规划提供外部参照，避免闭门造车，也明确哪些特性与我们的隐私承诺冲突。

## 1. 项目速览

| 项目 | 平台 | 形态 | 许可 | 一句话特色 |
|---|---|---|---|---|
| **Rime / librime**（鼠须管、小狼毫、fcitx5-rime、ibus-rime） | 全平台 | C++ 引擎 + YAML 方案 DSL | BSD-3 / GPL-3（前端） | 方案可编程：拼写代数（模糊音/方言）、Lua 插件、OpenCC 简繁、反查、自造词引擎 |
| **fcitx5**（+ fcitx5-chinese-addons / libime） | Linux/BSD（macOS/Android/Windows 有移植） | 通用框架 + addon | LGPL-2.1+ | addon 生态：拼音整句、云拼音（可选）、quickphrase、剪贴板、Unicode、emoji |
| **Mozc** | Android/macOS/ChromeOS/Linux/Windows | 日语转换引擎 | BSD-3 | 预测（サジェスト）、学习、部分确定/再转换、日期数字转换 |
| **McBopomofo 小麥注音** | macOS（+Win/Linux） | 注音 | MIT | 注音智慧选字、词组/语意选字、逐字/逐词、简繁 |
| **libchewing 新酷音** | 库 | 注音 | LGPL-2.1 | 智慧选字、多键盘布局（大千/许氏/IBM/汉拼…）、用户词 |
| **PIME** | Windows | TSF + Python 后端 | LGPL-2.1 | 用 Python/Node 快速写 Windows 输入法插件（注音/仓颉/速成等） |
| **azooKey** | iOS/iPadOS（+macOS） | Swift | MIT | 神经假名汉字转换 Zenzai、live conversion、自定义键/标签页 |
| **Trime 同文** | Android | librime JNI | GPL-3 | Rime 全方案生态搬到 Android，方言/形码/拼音同平台 |
| **fcitx5-android** | Android | fcitx5 框架 | LGPL-2.1 | 插件体系、物理键盘浮动候选、剪贴板、主题（monet）、符号/表情 |
| **kime** | Linux（XIM/Wayland/GTK/Qt） | Rust 韩语引擎 | GPL-3 | 性能与内存占用、无 segfault、自定义布局 |
| **HeliBoard** | Android | AOSP 派生 | GPL-3 | 100% 离线无网络权限、多语言混输、词典/表情搜索、剪贴板、配置备份 |
| **FlorisBoard** | Android | Kotlin | Apache-2.0 | 剪贴板历史、主题、扩展体系、表情历史 |
| **FUTO Keyboard** | Android | LatinIME 派生 | FUTO Source First 1.1（非 OSI） | 100% 离线 + **端上语音输入**、自研滑行输入、预测纠错 |
| **ddskk / SKK** | Emacs 等 | 假名汉字 | GPL-3 | 辞书式转换、学习、略语 |
| **libpinyin** | 库 | 拼音整句 | GPL-3 | n-gram 整句语言模型（ibus/fcitx 使用） |

## 2. 功能对标

### 2.1 转换质量

| 能力 | 代表实现 | 说明 |
|---|---|---|
| 整句 / 语言模型 | libpinyin、libime、Mozc | n-gram 或混合模型；Mozc 有独立的转换/候选管线 |
| 神经转换 | azooKey **Zenzai** | 小模型端上神经假名汉字转换，已上架 iOS；验证了「端上小模型提质量」的可行性 |
| 自学习 | Rime userdb、libchewing、HeliBoard（可备份 learned words）、Mozc 学习 | 用户词 + 频次，普遍支持导出/备份 |
| 模糊音 / 纠错 | Rime **Spelling Algebra**、libime 模糊音 | 配置式创建变体拼写，覆盖方言与口音 |
| 简繁 / 异体 | Rime OpenCC、McBopomofo、fcitx5 | 转换表离线内置 |
| 反查 | Rime（拼音反查五笔/仓颉/笔画） | 形码用户友好；学习成本高但黏性强 |
| 预测 / 联想 | fcitx5 predict、Mozc サジェスト、HeliBoard next-word | 基于上下文/历史的候选建议 |
| Live conversion | azooKey、Mozc 部分确定 | 边打边转换，减少确认操作 |
| 中英混输 | HeliBoard 多语言、fcitx5-android | 不切模式直接混打 |
| 表情 | fcitx5 emoji（CLDR）、HeliBoard emoji 词典搜索 | 关键词搜索表情 |

### 2.2 编码与键盘形态

- **虚拟键盘定制**：HeliBoard 可改布局/符号/数字/功能键，支持单手、分屏、数字键盘；fcitx5-android 计划中。
- **滑行输入**：FUTO 自研；HeliBoard 因无兼容开源库，需要用户自备闭源库（教训：核心体验别依赖闭源组件）。
- **语音输入**：FUTO 端上离线语音（whisper 类模型），是目前开源键盘里最完整的本地语音方案。
- **多键盘布局**：libchewing 内置大千/许氏/IBM/汉拼等 9 种注音布局。

### 2.3 UI 与候选

- 候选窗皮肤/主题：Weasel（wiki 定制）、Squirrel 主题、fcitx5-android（monet 动态色）。
- 物理键盘浮动候选：fcitx5-android；可展开候选视图。
- 剪贴板历史：fcitx5、FlorisBoard、HeliBoard、fcitx5-android 都是标配。
- 表情历史/建议：FlorisBoard、HeliBoard。
- 输入法桌宠：**主流开源项目基本没有**（多为商业输入法玩法），是我们的差异化空间。

### 2.4 数据与配置

- 方案 DSL 与词库分发：Rime schema + plum + 雾凇拼音生态，是目前最成熟的社区词库体系。
- 自定义短语：Rime `custom_phrase`、fcitx5 `quickphrase`。
- Unicode / 特殊符号：fcitx5 unicode addon、HeliBoard 科学符号词典、Rime 社区 u 模式方案。
- 配置与数据备份：HeliBoard 备份设置与学习数据；Rime sync（目录/WebDAV 插件）。
- 云拼音：fcitx5 cloudpinyin（可选）——**与我们的隐私承诺冲突，明确不做**。

### 2.5 生态与架构

- 插件体系：Rime **Lua**、PIME **Python/Node**、fcitx5 **addon**、FlorisBoard extension。
- 单引擎多前端：kime（Rust，XIM/Wayland/GTK/Qt）、librime（多平台前端）。
- 隐私定位：Rime 全本地、HeliBoard 无网络权限、FUTO 离线语音——与我们同路线。

## 3. 对 InputFlow 的启示（落地清单）

**P0（M1 收尾）**

1. **AI 辅助短语**：不提供手动「自定义短语」表（实际使用频次太低、维护成本高）。
   改为本地统计模型自动学习常用短语/搭配，重的短语补全交给可选小模型（ADR-0004 L2）。
2. **简拼 / 混拼**：全拼模式下只打几个字母就能出词（`nh`→你好、`bj`→北京、
   `nhao`→你好 这种任意混拼）；对标 Rime 简拼与主流商业输入法。
3. **Unicode / 符号输入**：`u` 前缀 + 常用符号/序号/货币表；对标 fcitx5 unicode、HeliBoard 符号词典。
4. **简繁转换**：导入 OpenCC 数据（纯数据离线），候选加「繁」切换。
5. **数据备份/恢复**：`userdata.enc` 导出为加密包（导出明文需二次确认），对标 HeliBoard 备份。

**P1（M2）**

5. **预测/联想**：已有二元组上下文，扩展到短语级与词尾联想；对标 fcitx5 predict。
6. **反查**：笔画/部首 → 拼音候选，服务生僻字；对标 Rime 反查。
7. **端上语音**：FUTO 验证了离线 whisper 路线；我们的 ADR-0004 L1/L2 已留好位置。
8. **桌宠双形态**：候选条吸附桌宠 + 双形态切换；开源无先例，做成设计卖点。

**P2**

9. **插件生态**：Lua/Python 与「内核零依赖」冲突 → 采用独立进程 + JSON-RPC 的宿主模式（与 ADR-0004 推理运行时同构）。
10. **词库社区分发**：plum 式索引 + sha256 校验，直接复用 AI 模型目录（`crates/ai`）的机制。

**明确不做**

- 云拼音 / 云候选（违反 ADR-0002 与隐私承诺）；
- 滑行输入（依赖闭源库，HeliBoard 的教训）——改为增强全拼的**简拼/混拼**来降低击键；
- 手动维护的「自定义短语」表——低频功能，用 AI 辅助短语替代；
- 需要账号或中心服务器的同步（保留自托管中继适配层，默认关闭）。

## 4. InputFlow 的差异化

- 零第三方运行时依赖内核（Rust）+ 单一 FFI，多前端复用；
- Liquid Glass 候选窗 + 桌宠，设计驱动；
- 用户词/剪切板 **加密落盘** + 密钥在钥匙串；
- 本地 AI 目录（Gemma/Qwen/Whisper）+ 统计模型，零云 API；
- 应用画像与双 `a` 手势这类「零配置智能」。

## 5. 参考链接（官方）

- Rime: https://rime.im · https://github.com/rime/librime · https://github.com/rime/plum
- 鼠须管: https://github.com/rime/squirrel · 小狼毫: https://github.com/rime/weasel
- fcitx5: https://fcitx-im.org · https://github.com/fcitx/fcitx5 · https://github.com/fcitx/fcitx5-chinese-addons
- fcitx5-macos: https://github.com/fcitx-contrib/fcitx5-macos · fcitx5-android: https://github.com/fcitx5-android/fcitx5-android
- Mozc: https://github.com/google/mozc
- McBopomofo: https://github.com/openvanilla/McBopomofo
- libchewing: https://chewing.im · https://github.com/chewing/libchewing
- PIME: https://github.com/EasyIME/PIME
- azooKey: https://github.com/azooKey/azooKey · 转换引擎: https://github.com/azooKey/AzooKeyKanaKanjiConverter
- Trime: https://github.com/osfans/trime
- kime: https://github.com/Riey/kime
- HeliBoard: https://github.com/HeliBorg/HeliBoard
- FlorisBoard: https://github.com/florisboard/florisboard
- FUTO Keyboard: https://keyboard.futo.org · https://github.com/futo-org/android-keyboard
- ddskk: https://github.com/skk-dev/ddskk
- libpinyin: https://github.com/libpinyin/libpinyin
