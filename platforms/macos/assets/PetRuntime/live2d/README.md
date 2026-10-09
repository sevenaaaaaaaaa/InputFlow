# Liana 桌宠 · Live2D 运行时（Bring-Your-Own）

本目录是 Liana 的 Live2D 桌宠运行时。遵循 **ADR-0009**：Live2D Cubism Core 与模型
**均不随包分发**，由用户自行获取，规避专有授权再分发风险。

## 随包分发的文件（MIT / 本项目）

| 文件 | 说明 |
|---|---|
| `pet-live2d.html` / `pet-live2d.js` | 本项目代码，暴露与 VRM 相同的 `window.pet*` 桥 |
| `vendor/pixi.min.js` | [pixi.js](https://github.com/pixijs/pixijs) v6（MIT） |
| `vendor/pixi-live2d-display.min.js` | [pixi-live2d-display](https://github.com/guansss/pixi-live2d-display) v0.4.0 `cubism4` UMD（MIT） |

> 依赖版本需匹配：pixi-live2d-display 0.4.x 需要 **pixi.js v6** 的 UMD 全局 `PIXI`。

## 用户自备（不随包、不覆盖）

放到 `~/Library/Application Support/Liana/live2d-user/core/`：

| 文件 | 来源 | 授权 |
|---|---|---|
| `live2dcubismcore.min.js` | Live2D 官方 [Cubism SDK for Web](https://www.live2d.com/en/sdk/download/web/) | Live2D **Proprietary** Software License（个人/小规模事业者免费，禁再分发） |

App 每次启动会把该目录内的文件合入运行时目录 `pet-runtime/live2d/`（单向、不覆盖用户目录）。

## 模型

Live2D 模型（`*.model3.json` + 贴图/`.moc3`/动作/表情）放形象包目录
`~/Library/Application Support/Liana/plugins/<id>/`，通过「导入 Live2D…」或目录下载获得。
**官方样例（Hiyori / Koharu / Mao / Miara 等）受 Free Material License 约束，禁止再分发**，
请从 [Live2D 官方样例页](https://www.live2d.com/en/learn/sample/) 自行下载并遵守其条款。

## 运行时缺失时的行为

缺少 Core / vendor 依赖时，`pet-live2d.js` 会向 Swift 侧回报 `{ needsRuntime: true }`，
桌宠界面据此显示一次性引导，并回退到内置 VRM 样例 / emoji，绝不空窗。
