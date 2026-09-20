# 里程碑

| 里程碑 | 内容 | 验收 |
|---|---|---|
| **M0 内核 + macOS 骨架**（本次） | Rust 内核（全拼/双拼/英文/日语假名）、词典格式与导入、FFI、macOS IMK 外壳 + 玻璃候选窗、桌宠设计稿 | `cargo test` 全绿；`build.sh` 产出 `.app` 可装载；中文输入可用 |
| **M1 可用与记忆** | 用户词加密持久化、剪切板历史、设置面板、macOS 打磨（标点/翻页/中英切换/emoji）、设计令牌生成器；本地 AI：模型目录/内存推荐/下载与 sha256 校验（`crates/ai` + 设置窗） | 日常可替代系统拼音；钥匙串/加密文件可验证；模型下载可校验、可删除 |
| **M2 日语与桌宠** | 假名→汉字（JMdict + Viterbi）、桌宠（macOS/Windows/Linux）与候选条双形态；神经模型运行时（llama.cpp/whisper.cpp，独立进程）接入候选重排与系统端上语音 | 日语整句转换可用；桌宠可切换形态；小模型可实际参与重排 |
| **M3 Windows + Linux** | TSF 服务、Fcitx5 addon、同步传输层（QUIC/TLS/mDNS）与配对 UI | 三桌面端同步用户词与剪切板 |
| **M4 移动端** | Android IME + JNI、iOS 键盘扩展（无 Full Access）、移动端候选 UI | 手机日常可用；iOS 内存 < 40MB |
| **M5 HarmonyOS + 自托管中继（可选）** | IME Kit/NAPI 适配、华为签名与上架材料；自托管中继适配层（默认关闭） | 鸿蒙真机可用；异地同步可自建 |

## 本次（M0）交付清单

- [x] 仓库骨架、AGPL-3.0、设计文档（PRD/架构/威胁模型/同步协议/ADR）
- [x] `crates/core`：候选/组合态/音节表/用户模型
- [x] `crates/dict`：IFD1 二进制 + TSV/Rime 导入 + 内置基础词典
- [x] `crates/pinyin`：全拼切分 + 双拼（小鹤/微软/自然码）+ Viterbi + 测试
- [x] `crates/en`、`crates/ja`（罗马字→假名）
- [x] `crates/sync`：HLC + LWW/G-Counter 合并内核 + 测试
- [x] `crates/engine`：会话编排（模式/翻页/学习重排）
- [x] `crates/ffi`：C ABI + JSON
- [x] `crates/xtask`：词典构建/导入 CLI
- [x] `platforms/macos`：IMK 外壳 + Liquid Glass 候选窗 + build/install 脚本

## 后续待办（M0 遗留）

- [ ] 双拼方案表逐键校对（`crates/pinyin/src/scheme.rs` 附校对清单）
- [x] 正式词库：rime-ice 20 万词条（`crates/dict/data/base-large.tsv`，含生成脚本与许可说明）
- [ ] 词频排序评测集扩充（首屏候选回归用）
- [ ] macOS 真机装载验证（需注销/重新登录后于「输入法」中启用）
- [x] 标点映射（未组合时中文全角标点、成对引号；数字保持半角）
- [ ] 候选窗动效与主题细节继续打磨
