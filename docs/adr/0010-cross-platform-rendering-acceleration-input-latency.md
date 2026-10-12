# ADR-0010：跨平台渲染 / 加速 / 触控差异化方案

状态：已接受（M5 规划）

## 背景

v0.4.0 完成六端架构落地后，实际差异浮出水面：

1. **渲染引擎差异巨大**。macOS 候选窗走 Core Animation/Metal 合成；Windows TSF
   根本没有自带 UI——候选窗要自己在 GDI/D2D/DWM 体系里画，字体走 ClearType；
   Linux/IBus 的候选默认由 GTK panel 绘制，引擎不拥有窗口；移动三端则是
   各自的 View/ArkUI 体系经系统合成器上屏。
2. **移动三端渲染逻辑与优先级不同**。Android（View → Skia → 硬件加速），
   iOS（responder chain → Core Animation，ProMotion 可变帧率 + 扩展进程
   ~60MB 内存红线），鸿蒙（ArkUI/ACE → 系统渲染，NAPI 边界）。
3. **GPU/NPU 加速各不相同**：Metal / DirectX / Vulkan / Skia 后端；
   NPU 侧 Core ML / DirectML / NNAPI(LiteRT) / MindSpore Lite。
4. **触控响应优先级不同**：iOS 系统边缘手势、Android 全面屏返回手势、
   鸿蒙左右滑都会与键盘手势竞争；同一手势在各端的响应链深浅不一。

如果强行"一套代码渲染所有端"（Flutter / 自绘），要么接不进 TSF/IBus/IME 容器，
要么引入重型依赖破坏「零依赖可审计」承诺。

## 决策

### 1. 总原则：渲染永远在壳层，"每端最优路径"而非"统一渲染技术"

- Rust 内核保持零依赖纯逻辑，**永不接触 GPU/NPU**；输入法 UI 极小但延迟极敏感，
  正确解法是让每端用本平台最顺的渲染栈。
- 不引入跨平台 UI 框架。统一靠「表现契约」（UNIFIED-DESIGN.md token +
  交互契约）而不是统一渲染器。
- 效果分级：Liquid Glass 级效果只在 Tier 1 端做满，Tier 2 端用同 token 的
  等价扁平呈现——**token 不分级，效果分级**。

### 2. 渲染分级矩阵 + 帧预算契约

| 端 | Tier | 窗口容器 | 绘制技术 | 字体体系 |
|---|---|---|---|---|
| macOS | 1（GPU 合成） | IMK 自有 NSWindow | Core Animation / CoreGraphics | CoreText |
| iOS | 1（GPU 合成） | 键盘扩展 UIView | Core Animation（无 Metal） | CoreText，内存红线内 |
| Android | 1（GPU 合成） | IME View 窗口 | View/Canvas（Skia，硬件加速） | 系统字体栈 |
| 鸿蒙 | 1（GPU 合成） | IME Panel（ArkUI） | ArkUI/ACE | 系统字体栈 |
| Windows | 2（CPU 绘制 + DWM 合成） | 自建 UIMessageWindow | D2D1（首选）/ GDI（回退） | DirectWrite/ClearType |
| Linux | 2（panel 绘制） | IBus LookupTable（GTK） | 先用 panel 原生渲染；自绘仅 GNOME Shell 扩展路线时 | fontconfig |

**帧预算契约**（验收用，不达标即回归）：

| 指标 | 预算 |
|---|---|
| 按键 → 候选可见 | ≤ 1 帧（60Hz=16ms；120Hz 端 ≤ 12ms） |
| 候选列表增量更新 | ≤ 1/2 帧 |
| 键盘首帧（调起） | ≤ 2 帧 |
| 触觉反馈延迟 | ≤ 10ms |
| 主线程禁止项 | 词典 IO / JSON 大对象 / 任何阻塞调用 |

词典加载策略随端分级：Android/iOS/鸿蒙首启落盘后 mmap 直读；macOS 沿用现状；
Windows/Linux 从安装目录直读。全端禁止在按键路径上发生文件 IO。

### 3. 触控优先级与手势仲裁表

**总约定：系统手势永远赢，我们的手势只在自己的视图矩形内主张。**

| 手势 | 主张方 | 让位规则 |
|---|---|---|
| 候选条目上滑上屏 | 我们 | 仅在候选条目矩形内；不拦横向滚动（候选栏自身滚动优先） |
| 退格长按连删 / 左滑清除 | 我们 | 长按先于左滑判定（300ms 阈值内位移小于滑动阈值） |
| Pad 分体中缝 | 预留 | 本版不注册任何手势，留空 |
| iOS 屏幕边缘手势 / 主页指示条 | 系统 | 键盘视图不贴屏边、不重载 preferredScreenEdgesDeferringSystemGestures |
| Android 返回手势（全面屏侧滑） | 系统 | 键盘根视图不伸入手势区；仅消费键盘矩形内的触摸 |
| Android 状态栏下拉 / 鸿蒙左右滑 | 系统 | 同上 |
| 鸿蒙 ArkUI 内置滚动/点击冲突 | 组件优先 | 用 gesture 优先级 API 显式声明，不做全局拦截 |

触控管线实现约定：Android 直接 `onTouchEvent`/`OnTouchListener`
（不叠 GestureDetector 嵌套仲裁）；iOS 用 gesture recognizer 且
`cancelsTouchesInView` 按需设置；触觉反馈走系统标准 API（Android
`HapticFeedbackConstants`、iOS `UIImpactFeedbackGenerator`），禁止自实现振动。

### 4. GPU/NPU 加速：可插拔后端，UI 永不依赖

- **GPU**：Tier 1 端由系统合成器自然使用 GPU，我们不再手动接 Vulkan/DirectX——
  输入法 UI 的绘制量撑不起自管 GPU 管线的复杂度；Windows D2D1 已是 GPU 加速路径。
- **NPU**：仅用于可选增强（本地语音识别、未来的本地大模型短语推荐），
  通过 `liana-ai` 模型目录的 `backend` 字段声明：
  `coreml` / `directml` / `litert`（原 NNAPI）/ `mindspore` / `cpu`。
- **永不依赖原则**：任何加速后端不可用时必须能干净降级到 CPU 路径；
  UI 渲染与核心输入路径的可用性不绑定 GPU/NPU。
- Rust 侧接口保持零依赖：后端选择由前端探测并传字符串，内核只做目录与预算管理。

### 5. 跨端一致性验收清单

每端 README 附验收记录，发布前跑一遍：

- [ ] 帧预算四项达标（或 Tier 2 端标注"可感知流畅"人工验收）
- [ ] 触觉延迟 ≤ 10ms
- [ ] 中文回退字体链正确（生僻字/Emoji 不豆腐块）
- [ ] 暗色 token 与 UNIFIED-DESIGN.md 一致（色值 diff 为零）
- [ ] 手势仲裁表逐项实测（重点：三端系统手势不被我们抢占）
- [ ] 无按键路径文件 IO（profiler 抽查）

## 备选方案（已否决）

1. **统一自绘 UI 框架（Flutter/RN/egui）**：TSF/IBus/鸿蒙 IME 没有对应容器，
   需要自建窗口注入系统输入框架，复杂度与风险远大于收益；且违反零依赖承诺。
2. **内核侧引入 Skia 统一绘制**：依赖爆炸 + 输入法 UI 绘制量太小，不值。
3. **强求六端像素级一致**：不同字体栈/DPI/合成器下做不到，且没必要——
   用户感知的一致性来自「布局结构 + token + 交互契约」，不是像素。

## 后续

- Windows/Linux 实机联调时按 §2 帧预算建测量脚本；
- 鸿蒙/Windows UI 对齐时按 §3 仲裁表逐项落地；
- `liana-ai` 增加 `backend` 字段（本地增强接入 NPU 的预留口）。