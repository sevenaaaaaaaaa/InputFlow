# ADR-0007：桌宠 = 皮肤资产 + 渲染器（放弃程序化绘制）

状态：已接受（M1）

## 背景

桌宠不是「功能」，是**视觉门面**：用户要的是可爱宠物、漂亮角色、动效丝滑、Retina 高清。
此前用 Python/AppKit 程序化画椭圆矩形（`genpets.py`）属于选型错误——代码画图天花板很低，
无论怎么调色都不可能达到「高级好看」。正确做法是把桌宠当作**皮肤资产 + 专用渲染器**，
像 Live2D/VRM 生态那样由美术产出、由渲染器播放。

## 决策

### 1. 插件契约：形象包声明渲染器

`pet.json` 增加 `renderer` 字段，前端按能力分发：

```json
{
  "renderer": "emoji | sprites | rive | live2d | vrm",
  "size": [220, 300],
  "anchor": "bottom-center",
  "states": { "idle": "...", "typing": "...", "commit": "..." },
  "gaze": true,
  "physics": ["hair", "skirt", "tail"],
  "entry": "model.model3.json | pet.riv | avatar.vrm | frames/"
}
```

- `emoji`：系统 emoji 角色（零成本兜底，已实现）
- `sprites`：分层 PNG + Core Animation（呼吸/眨眼/头发摆动/注视，2x–3x 高清）
- `rive`：矢量状态机（.riv，运行时 MIT，体积小、任意分辨率清晰）
- `live2d`：Cubism（二次元美少女的事实标准，模型可做眨眼/口型/物理/注视）
- `vrm`：3D 虚拟形象（开放规范，VRoid Studio 免费建模，弹簧骨物理 + 注视）

未实现的渲染器要**明确报错**（气泡提示「该形象包需要 X 渲染器」），不允许静默降级成丑图。

### 2. 技术选型（按优先级）

| 方案 | 视觉上限 | 授权 | 资产来源 | 集成成本 |
|---|---|---|---|---|
| **VRM 3D（three-vrm / Model I/O）** | 高（VRoid 级 3D） | VRM 规范开放；three-vrm MIT；VRoid Studio 免费 | VRoid Hub（大量 CC0/CC-BY） | 中（WKWebView + WebGL 或原生 Metal） |
| **Live2D Cubism** | 极高（VTuber 级） | 专有：免费档有营收/署名限制，需评估与 AGPL 兼容 | Cubism Editor（免费档）+ 官方样例模型可测试 | 中高（Cubism Native/Web SDK） |
| **Rive** | 中高（矢量状态机） | 运行时 MIT；编辑器免费档 | Rive 社区 | 低（SPM 包） |
| **分层 sprites + Core Animation** | 中高（取决于美术） | 无 | 画师（Krita/PS/Aseprite） | 低 |
| **程序化绘制（已否决）** | 低 | — | — | — |

**推荐路径**：
1. 现在：`emoji` 兜底（可用）+ `sprites` 分层渲染器（把「动画系统」先做对：眨眼、呼吸、
   注视鼠标、状态交叉淡入、60fps 仅打字时开启、窗口遮挡自动降频）；
2. 主推：**VRM**（开放授权、免费建模、3D 注视与物理），用 `WKWebView + three-vrm` 快速落地，
   或原生 `GLTFKit2 + SceneKit/Metal`；
3. 可选：**Live2D**（若确认许可边界）用于「漂亮美女」类形象包，走独立渲染进程隔离。

### 3. 动画与画质要求（所有渲染器共同遵守）

- 资产 2x–3x，`contentsScale` 跟随屏幕，禁止位图拉伸糊化；
- 状态机：`idle`（低帧率、随机小动作）、`typing`（跟手 60fps）、`commit`（一次性庆祝）；
- 交互：注视鼠标（瞳孔/头部）、点击回应、悬停反应、可拖动；
- 物理：头发/裙摆/尾巴用弹簧骨或 Rive/Live2D 自带物理；
- 性能：窗口遮挡或空闲自动降频/暂停；内存预算 < 120MB（单形象）。

### 4. 资产管理

- 形象包放 `~/Library/Application Support/InputFlow/plugins/<id>/`，随包分发的示例在
  `examples/plugins/`，版本变化自动更新；
- 角色资产不进 Git 大文件：分发走独立资源包（复用 AI 模型目录的 sha256 校验机制）；
- 授权字段必填（`license`），非商用/需署名资产必须在 `plugin.json` 里写明。

## 结果

- 好：桌宠质量取决于美术资产，与代码解耦；可逐步接入 VRM/Live2D 而不改内核；
- 代价：需要真实美术/模型资产，且 Live2D 需单独评估授权；
- 明确否决：继续用程序化绘制充当「形象」。
