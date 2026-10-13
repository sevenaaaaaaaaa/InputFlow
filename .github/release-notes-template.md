## 下载与安装

### macOS 13+（universal：Apple Silicon + Intel）
1. 下载 `Liana-*.dmg` 并打开
2. 双击**松萝安装器**：若提示「无法验证开发者」，**右键 → 打开**，
   或到 系统设置 → 隐私与安全性 → 点**仍要打开**
3. 安装器会清 quarantine、装到「输入方法」并引导收录。手动党可拖 `Liana.app`
   进 Applications 后执行：`xattr -dr com.apple.quarantine /Applications/Liana.app`
4. 系统设置 → 键盘 → 输入法（简体）→ **+** → **松萝**；列表没有就注销重登一次

> 安装包为 ad-hoc 签名、未经 Apple 公证（免费账号无公证资格），放行一次即可；
> 「任何人双击即用」需付费 Developer ID 证书。

### Android 7.0+
下载 `Liana-*-android.apk` 直接安装（允许「安装未知应用」）。
若从临时签名版本升级报「签名冲突」，卸载重装即可；配置固定签名见
`.github/workflows/release.yml` 头注释。

### Linux（x86_64 · ibus）
```bash
tar xzf liana-*-linux-x86_64.tar.gz
cd liana-*/
sudo ./install.sh          # 装到 /usr/local/lib/liana + ibus 组件声明
ibus restart               # ibus-setup → 输入法 → 添加 → 中文 → 松萝
```

iOS / Windows / HarmonyOS 尚在骨架阶段，暂不提供安装包。

## 校验和（SHA-256）
```
