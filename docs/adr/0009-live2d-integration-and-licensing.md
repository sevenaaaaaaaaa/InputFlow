# ADR-0009：Live2D 桌宠 = 自带运行时 + 自带模型（授权优先）

状态：已接受（M2）

## 背景

桌宠是视觉门面（ADR-0007）。VRM 已落地，但社区公认「VTuber 级美观 + 完备交互
（碰撞判定 / 眼神追踪 / 动作组 / 物理）」的资产主要是 **Live2D Cubism**。直接拆包商业游戏
模型（原神、碧蓝航线等）有严重的版权与再分发风险，**明确禁止**。

Live2D 的授权分三层，且与本项目 AGPL-3.0 + 「零第三方依赖 / 可审计 / 插件是数据不是代码」
承诺存在正面冲突：

| 层 | 授权 | 关键约束 |
|---|---|---|
| **Cubism Core**（运行时本体） | Live2D **Proprietary** Software License | 不在 GitHub 发布；**不得以非 Live2D 许可（即开源许可）发布其代码/内容**；再分发须另行签约 |
| **SDK Release License** | Publication License Agreement | 个人 / 小规模事业者（年营收 < 1000 万日元）免费免签约；超阈值须签约付费 |
| **样例模型**（Hiyori / Koharu / Mao / Miara …） | Free Material License | 个人 / 小规模可商用非商用使用，但 **No Redistribution**、不可转授权；合作角色（Zundamon/Miku/Unity-chan）另有条款 |

结论：**把 Cubism Core 或官方样例模型打进 AGPL 仓库/安装包，会触发授权冲突。**

## 决策

### 1. Bring-Your-Own（方案 A）

- **不随包分发** Cubism Core 与任何 Live2D 模型；
- 用户自备 Core 放 `~/Library/Application Support/Liana/live2d-user/core/`，
  模型放 `~/Library/Application Support/Liana/plugins/<id>/`；
- `PetRuntimeStore` 把用户 Core **单向合入**运行时目录（`pet-runtime/live2d/`），
  运行时目录随包同步时会重建，但用户目录不覆盖、可回滚。

### 2. 只分发我们自己的代码 + MIT 依赖

随包仅含 `assets/PetRuntime/live2d/` 下的本项目 HTML/JS，以及 MIT 的
`pixi.js` / `pixi-live2d-display`。Cubism Core 由用户在运行时补齐。

### 3. 模型来源白名单

- 只用 **官方 / 明确授权** 渠道（Live2D 官方样例页、作者授权页、CC0 模型）；
- **禁用**社区整合仓库（如 Eikanya/Live2d-model）——其通常不授予模型再分发权；
- 目录（`PetCatalog`）只存**元数据**（名称 / 官方下载页 / 许可 / 署名），不存模型本体。

### 4. 默认 Live2D，但优雅回退

新增偏好 `LianaPetRenderer`（默认 `live2d`）。渲染解析顺序：

```
用户选定形象包(有效) → 首选渲染器=live2d 且已装 live2d 包
  → 内置 VRM 样例(pet-vrm-sample) → emoji
```

运行时/模型缺失时，JS 回报 `{ needsRuntime: true }`，界面显示一次性引导并回退，
**绝不空窗、绝不静默降级成丑图**（延续 ADR-0007 第 36 行原则）。

### 5. 交互映射（兼顾互动与美观）

`pet.json` 声明：`renderer:"live2d"`、`entry:"*.model3.json"`、`scale/anchor/framing/zoom`、
`states`（状态→动作组）、`moods`（情绪→表情）、`hit_areas`（命中区→动作）。
运行时用 `model.focus()`（眼神）、`model.hitTest()`（碰撞判定）、`model.motion()` /
`model.expression()`（动作组/表情），物理用 model3.json 自带。

### 6. 合规元数据与同意

`plugin.json` 的 `license` 必填，非商用/需署名资产写明；首次启用 Live2D 时展示授权说明并
记录用户同意。

## 结果

- 好：以最小授权风险获得 VTuber 级形象与完备交互；与 AGPL 承诺的冲突被隔离在「用户自备」边界内；
- 代价：默认 Live2D 在未装运行时/模型时必然处于回退态，需引导与回退保证体验；
- 风险：Cubism + 多贴图模型内存高于 VRM，默认仍需可一键切回 VRM / emoji；
- 明确否决：随包分发 Cubism Core / 官方样例模型；拆包商业游戏模型。
