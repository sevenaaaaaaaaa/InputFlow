# ADR-0001：Rust 内核 + 各平台原生外壳

状态：已接受（M0）

## 背景

六平台输入法，若每端各写一套引擎，词库/算法/学习行为会分叉，且无法共享测试。
若用一套跨平台 UI（如 Qt/Flutter）覆盖全部，输入法在多数平台无法集成（IMK/TSF/Fcitx/IME Kit 都要求原生服务形态）。

## 决策

- 引擎、词典、同步合并全部放 `crates/`（纯 Rust、零第三方依赖），经 `crates/ffi` 暴露 C ABI + JSON。
- UI 与系统集成**每平台原生**：macOS InputMethodKit、Windows TSF、Linux Fcitx5、Android InputMethodService、iOS 键盘扩展、HarmonyOS IME Kit。
- 视觉一致性不靠共享 UI 框架，而靠**共享设计令牌**（`docs/design-tokens.json`）+ 各端原生实现。

## 结果

- 好：算法/词典/测试单点维护；平台侧只做「按键翻译 + 渲染」；天然满足「不联网」（内核无网络代码）。
- 代价：UI 需要每平台实现一遍（约 6 套），桌宠/候选窗是主要重复成本；用令牌生成器和组件清单降低。
- 明确否决：Electron/Qt 全平台 UI（无法满足输入法服务形态与 iOS 内存预算）。
