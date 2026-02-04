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


## 📦 构建安装包 (快速上手)

详细步骤与踩坑说明请看仓库根目录的 `构建安装包.md`。

软件要求: **Xcode**, **xcode-select (CLI tools)**, **dpkg-deb** (brew install dpkg)。

```bash
# build
rm -rf build Payload out
xcodebuild -scheme "ChargeLimiter" -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO ARCHS=arm64

# TrollStore
mkdir -p Payload out
cp -a build/Build/Products/Release-iphoneos/ChargeLimiter.app Payload/ChargeLimiter.app
zip -r out/ChargeLimiter_<VERSION>_TrollStore.tipa Payload
rm -rf Payload

# roothide (arm64e)
rm -rf ChargeLimiter/Package_rootless/var/jb/Applications/ChargeLimiter.app
cp -a build/Build/Products/Release-iphoneos/ChargeLimiter.app \
  ChargeLimiter/Package_rootless/var/jb/Applications/ChargeLimiter.app
dpkg-deb -Zxz -b ChargeLimiter/Package_rootless out/ChargeLimiter_<VERSION>_roothide_arm64e.deb

# rootless (arm64)
rm -rf ChargeLimiter/Package/Applications/ChargeLimiter.app
cp -a build/Build/Products/Release-iphoneos/ChargeLimiter.app \
  ChargeLimiter/Package/Applications/ChargeLimiter.app
dpkg-deb -Zxz -b ChargeLimiter/Package out/ChargeLimiter_<VERSION>_rootless_arm64.deb
```

