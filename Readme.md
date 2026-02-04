# 修改什么

1. **界面重构**：将原有 WebView 界面全部替换为原生 UIKit，整体风格更现代、流畅。
2. **功能精简**：彻底移除了悬浮窗（浮窗）相关功能和代码，还有一些我一直都不用的功能。

预览图如下，感谢原作者的开发

<p align="center">
  <img src="https://raw.githubusercontent.com/tunecc/ChargeLimiter/refs/heads/main/screenshots/1.PNG" width="200" />
  <img src="https://raw.githubusercontent.com/tunecc/ChargeLimiter/refs/heads/main/screenshots/2.PNG" width="200" />
  <img src="https://raw.githubusercontent.com/tunecc/ChargeLimiter/refs/heads/main/screenshots/3.PNG" width="200" />
  <img src="https://raw.githubusercontent.com/tunecc/ChargeLimiter/refs/heads/main/screenshots/4.PNG" width="200" />
</p>


## 📦 Building & Packaging (快速上手)

**Quick start:** 编译 → 复制 `.app` 到对应 `Package` 模板目录 → 打包。更多详细步骤见：`构建安装包.md`。

Prerequisites: **Xcode**, **xcode-select (CLI tools)**, **dpkg-deb** (brew install dpkg)。

示例命令（使用占位符 `$OUTDIR`、`<VERSION>`）：

- 构建 App：
```bash
rm -rf build
xcodebuild -scheme "ChargeLimiter" -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO ARCHS=arm64
```
- 生成 TrollStore (.tipa)：
```bash
mkdir -p Payload
cp -r build/Build/Products/Release-iphoneos/ChargeLimiter.app Payload/
zip -r "$OUTDIR/ChargeLimiter_<VERSION>_TrollStore.tipa" Payload
rm -rf Payload
```
- 打包 .deb（示例）：
```bash
# rootless (roothide)
dpkg-deb -Zxz -b ChargeLimiter/Package_rootless "$OUTDIR/ChargeLimiter_<VERSION>_roothide_arm64e.deb"
# rootful
dpkg-deb -Zxz -b ChargeLimiter/Package "$OUTDIR/ChargeLimiter_<VERSION>_rootful_arm64.deb"
```

**Checklist（发布前）**: 更新 `MARKETING_VERSION`、检查 `DEBIAN/control`（Package/Version/Arch）、确认脚本权限并在真机测试。

（详细步骤请参见仓库根目录的 `构建安装包.md`）
