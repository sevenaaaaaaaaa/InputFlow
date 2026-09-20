# ADR-0003：Liquid Glass 用原生 API，其他平台按同一令牌近似

状态：已接受（M0）

## 背景

Liquid Glass 是苹果在 macOS/iOS 26 引入的系统材质。第三方若自行「伪造」会在系统更新后不同步；
而 Windows/Linux/Android/HarmonyOS 没有等价物，完全不做又失去产品辨识度。

## 决策

- 苹果平台：优先系统原生（`NSGlassEffectView` / SwiftUI `glassEffect` / UIKit 对应 API），
  运行时不满足版本则回退 `NSVisualEffectView`（macOS）/ `UIVisualEffectView`（iOS）。
- 其他平台：实现「模糊 + 饱和 + 高光描边 + 细噪点 + 折射位移」的近似材质，
  参数全部来自 `docs/design-tokens.json`，与苹果端共享明暗、圆角、弹簧动效。
- 不做自定义 shader 复刻苹果原生效果（版本漂移不可控）；近似层保证观感同源即可。

## 结果

- 好：苹果端永远跟随系统最新材质；其他平台有稳定可预期的玻璃观感。
- 代价：跨平台观感存在差异（这是有意为之，不是缺陷）。
