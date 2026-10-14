# CLAUDE.md — InputFlow（松萝 Liana）

## 项目简介

松萝（Liana）是隐私优先的跨平台输入法：本地引擎、无服务器、仅局域网 E2EE 同步。六端（macOS / Android / iOS / Linux / HarmonyOS / Windows）共用同一 Rust 内核，通过 C ABI（`liana.h`）接入各平台。macOS 为日常可用端，其余平台处于构建/联调阶段。详见 `README.md`、`docs/architecture.md`、`docs/adr/`。

## 技术栈

- Rust（edition 2024，rust-version 1.85）Cargo workspace，内核零第三方依赖
- 平台层：macOS（Swift + InputMethodKit，swiftc 手工打 bundle）、iOS（Swift 键盘扩展，XcodeGen `project.yml`）、Android（Kotlin + JNI，Gradle KTS）、Linux（IBus，Python/GI + ctypes）、HarmonyOS（ArkTS + NAPI）、Windows（C++ TSF COM）
- License：AGPL-3.0-only

## 目录结构

```
crates/        内核 crates：core、dict、pinyin、en、ja、emoji、symbol、sync、zhconv、engine、ai、plugin、ffi（C ABI）
xtask/         构建工具（词库构建/导入、插件脚手架、准确率评测）
platforms/     各平台集成：macos/ ios/ android/ linux/ harmonyos/ windows/
examples/      插件示例
docs/          PRD、架构、ADR、同步协议、威胁模型、设计 token
tools/         零散工具
dist/ target/  构建产物（gitignored）
```

## 常用命令

```bash
cargo test                                   # 内核测试（全绿是合并底线）
cargo build --release -p liana-ffi           # 构建内核静态库

# macOS
./platforms/macos/build.sh                   # 构建 Universal 输入法（UNIVERSAL=0 单架构）
./platforms/macos/install.sh                 # 安装到 ~/Library/Input Methods
./platforms/macos/uninstall.sh

# 其他平台
./platforms/ios/build.sh
./platforms/android/build_native.sh
./platforms/linux/build.sh
./platforms/harmonyos/build_ohos.sh
platforms\windows\build.cmd

# xtask
cargo run -p xtask -- dict build <input.tsv> -o <out.ifd> [--with-base]
cargo run -p xtask -- dict stats <file>
cargo run -p xtask -- plugin new --kind skin --id skin-mine --name 我的皮肤
cargo run -p xtask -- plugin check plugins/skin-mine
cargo run -p xtask -- accuracy [--hard]
```

lint：无项目级配置（可用标准 `cargo clippy` / `cargo fmt`）。

## 部署方式

无服务器部署（产品本身无服务端）。分发方式为 macOS 签名打包：

```bash
./platforms/macos/dist.sh                # 签名 → Hardened Runtime → 公证 → DMG → staple → sha256，产物在 dist/
./platforms/macos/dist.sh --skip-build   # 复用已有构建产物
```

- 签名三级降级：Developer ID（可公证分发）→ Apple Development（仅本机）→ ad-hoc
- 本机只有 Apple Development 证书 → DMG 未公证，靠 DMG 内的放行助手解决「已损坏」
- CI：`.github/workflows/release.yml` 在推 `v*` tag 时构建三平台；Release 已存在时只补传缺失产物，不覆盖本地上传的 DMG
- 仓库已改名：GitHub `sevenaaaaaaaaa/liana`（原 inputflow，旧地址自动跳转）；本地目录仍是 `~/InputFlow`
- 分支 `main`（另有本地分支 `m1-p0-wrapup`、远端分支 `ui-glass-and-accuracy`）

## 发版（每日）

**硬性规则：每天开发结束必须跑一次 daily-release（或由 launchd 自动跑）。**

```bash
scripts/daily-release.sh              # 正式发版
scripts/daily-release.sh --dry-run    # 只测试 + 本地打 DMG，不 commit/tag/push/release/安装
scripts/daily-release.sh --no-install # 发版但不更新本机输入法
scripts/daily-release.sh --force      # 自上个 tag 无新提交也发
```

- 流程：必须在 `main` 且工作区干净（否则打印改动并以「skipped」退出 0，绝不替你提交 WIP）→ 落后则 `pull --rebase --autostash`（冲突即 abort 失败）→ `cargo test` → 上个 `v*` tag 后无新提交则跳过 → patch +1 并统一写入 `Cargo.toml`/`Cargo.lock`、`platforms/macos/Info.plist`、`platforms/macos/installer/Info.plist`、Android `versionName`(+`versionCode`)、iOS `project.yml` `MARKETING_VERSION` → 提交 `chore(release): vX.Y.Z` + 附注 tag → `dist.sh` 打 DMG 并挂载校验 → push main 与 tag → `gh release create`（说明 = 上个 tag 以来的提交标题 + 安装指引 + sha256）→ 优雅退出本机输入法，按 `.bundle-id`（本机 dev id）重建并 `install.sh` 装到 `~/Library/Input Methods`，去隔离后重新拉起。
- 中途失败可重跑（会从 HEAD 上的发版提交续跑）；单实例锁；日志 `~/Library/Logs/liana-daily-release.log`。
- **macOS 放行助手**：DMG 内含 `Liana.app`、`松萝安装器.app`、`Applications` 链接、`打不开？双击我.command`、`安装说明.txt`；模板在 `packaging/macos/`，由 `dist.sh` 拷入。
- **改名禁区（勿动，否则用户数据/输入法注册失效）**：钥匙串服务名与偏好域 `dev.inputflow.inputmethod`、本机 `.bundle-id`（`dev.inputflow.inputmethod.dev`）、`main.swift` 迁移逻辑与 `uninstall.sh` 里的旧名。

## 注意事项

- 构建相关环境变量：`CODESIGN_IDENTITY`、`BUNDLE_ID`、`UNIVERSAL`、`MACOSX_DEPLOYMENT_TARGET`、`NOTARY_PROFILE`（默认 `liana-notary`，notarytool 凭据档案名）
- 本机 bundle id 覆盖写在 `platforms/macos/.bundle-id`（gitignored）
- 内核保持零第三方依赖；平台层改动不应要求改内核（经 `crates/ffi` 的 C ABI）
- 新输入法安装后若系统列表不显示，需注销重登；macOS 26+ 仅收录有效签名的输入法
