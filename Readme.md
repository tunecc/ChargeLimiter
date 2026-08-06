# ChargeLimiter

一个面向 iPhone 的充电控制工具，用来减少设备长时间停留在高电量、高温和长期满充状态，同时尽量不影响日常使用。

> 它不是硬件级旁路充电。
>
> 当前实现仍是软件层策略控制，会结合电量、温度、外部供电状态、系统优化充电状态和守护进程逻辑，决定何时停充、何时恢复充电，以及何时临时协调系统优化充电。

<p align="center">
  <img src="https://raw.githubusercontent.com/tunecc/ChargeLimiter/refs/heads/main/screenshots/1.PNG" width="200" />
  <img src="https://raw.githubusercontent.com/tunecc/ChargeLimiter/refs/heads/main/screenshots/2.PNG" width="200" />
  <img src="https://raw.githubusercontent.com/tunecc/ChargeLimiter/refs/heads/main/screenshots/3.PNG" width="200" />
  <img src="https://raw.githubusercontent.com/tunecc/ChargeLimiter/refs/heads/main/screenshots/4.PNG" width="200" />
</p>

## 当前定位

ChargeLimiter 本质上是一个充电策略调度器，不是硬件电源路径改造器。

它会根据你设定的规则和当前电池状态，决定：

- 是否允许继续充电
- 是否进入停充
- 是否进一步禁止电流继续流入设备
- 是否临时协调系统优化充电
- 是否在定时窗口内暂时放开电量上限

适用环境：

- TrollStore
- 越狱 rootful
- 越狱 rootless
- 越狱 roothide（原生 scheme / `Package_roothide`）

## 当前版本能做什么

- 电量上限 / 下限控制
- `智能停充`：优先使用 `PredictiveChargingInhibit` 抑制充电，不生效时自动回退到传统停充路径
- `停止电量=100% 时交由系统控制`
- `停充时启用禁流`
- 温度控制
- 系统优化充电协调与 `永久停用系统优化充电`
- `满充计划`
- `限流等级` 与 `Powercuff` 高温模拟
- `加速充电`
- `策略诊断`
- `历史统计`
- `策略事件时间线`
- 导出诊断摘要、事件时间线和长测校准模板

## 适合谁

- 你希望 iPhone 长期插电时，不要一路慢慢充到 100%
- 你希望把设备长期保持在一个更低、更稳定的电量区间
- 你经常边充边用，想更清楚地知道“现在到底为什么停充 / 限流 / 禁流”
- 你愿意在“续航上限、温度、性能、充电速度”之间自己做取舍

## 使用前先知道

### 1. 它不是硬件旁路充电

ChargeLimiter 不会把 iPhone 改造成安卓游戏手机上那种“外部供电直通、完全绕过电池”的硬件旁路方案。

它做的是：

- 通过软件控制停充 / 恢复充电
- 在需要时进入更激进的禁流状态
- 在高温或特定策略下调整系统热状态和充电行为

### 2. `停止充电 = 100%` 和 `交由系统控制` 不是一回事

代码当前把这两个概念分开了：

- 如果你把 `停止充电` 设为 `100%`，但没有打开 `停止电量=100% 时交由系统控制`
  - ChargeLimiter 仍然继续参与电量上限控制
- 如果你同时打开了 `停止电量=100% 时交由系统控制`
  - 电量上限会交回系统
  - 软件侧只保留温度相关保护

### 3. `停充时启用禁流` 是更激进的模式

它不只是“不给电池继续充电”，而是尽量不再让外部电流继续流入设备。

这意味着：

- 插着线时，当前负载会更多由电池自己承担
- 体感上可能更接近“插着线但仍然掉电”

适合：

- 你明确知道自己在追求更激进的停充效果
- 你愿意接受插电玩游戏 / 导航 / 录屏时电量下滑

### 4. 高温通常比少掉 1% 电更值得优先处理

Apple 官方对 iPhone 电池寿命的说明里，明确把 `温度历史` 和 `充电模式` 视为影响化学老化的重要因素；设备过热时，系统本身也会降低或停止充电。

所以遇到效果不理想时，通常优先看：

- 当前温度
- 当前是否仍在高负载
- 是否真的需要继续追求更高充电速度

### 5. 历史统计和策略事件时间线现在已经联动

当前代码里：

- `历史统计` 用于 5 分钟 / 小时 / 天 / 月曲线
- `策略事件时间线` 用于保存最近的持久化策略事件
- 右上角统计开关关闭时，会停止继续采集
- 如果关闭时选择 `删除历史记录`
  - 曲线数据会一起清掉
  - `策略事件时间线` 也会一起清掉

## 功能说明

### 主页面

主页面当前聚焦的是“当前状态 + 快速调节 + 供电环境”。

你会看到：

- `停止充电 (电量 ≥)` 主滑块
- 当前供电状态、充电命令、系统停充抑制、系统优化充电状态
- 适配器功率、电压等供电环境
- 电池健康、温度、电流、电压、循环次数

如果当前没有外部供电，页面会更偏向展示实时状态；如果插着线，则会更容易看出当前到底是：

- 正在充电
- 已停止充电
- 温控暂停
- 禁流中

### 充电高级

`充电高级` 页是当前版本最核心的设置入口。

#### `智能停充`

- 停充时优先走 `PredictiveChargingInhibit`
- 如果系统拒绝写入，或者停充命令发出后一段时间仍未进入抑制态
- daemon 会自动回退到传统 `IsCharging` 停充路径

这是当前更推荐的默认停充方式。

#### `停止电量=100% 时交由系统控制`

- 开启后：100% 上限交给系统
- 关闭后：即使上限是 100%，本工具仍继续参与控制

这项设置主要决定 100% 场景到底由谁接管，而不是普通 50% / 80% 这类上限场景。

#### `停充时启用禁流`

- 达到停充条件后，进一步禁止电流流入设备
- 比单纯停充更激进

不建议一上来就开。

#### 系统优化充电

当前实现有两条相关路径：

- `永久停用系统优化充电`
- 运行时在需要软件接管时，临时协调系统优化充电状态

代码当前已经做了：

- 进入接管前记录系统原始状态
- 生成协调会话 ID
- daemon 重启后重新判断是继续接管还是恢复
- 如果系统状态被外部改变，结束当前接管会话，避免误恢复

#### `满充计划`

适合平时不想长期满电，但偶尔仍想有一次完整满充的人。

可配置：

- `每隔天数`
- `开始时间`
- `持续时长`

满充窗口内会临时放开电量上限，但温度控制仍继续生效。

#### `限流等级`

它不是直接对 PMIC 下发一个固定安培数，而是通过更保守的热状态模拟，让系统整体倾向于更低功耗、更保守的充电行为。

可选：

- `关闭`
- `正常`
- `轻度`
- `中度`
- `重度`

档位越高，系统通常越保守，充电速度和前台性能也可能越受影响。

#### `高温模拟 (Powercuff)`

用于设置默认热状态模拟等级。

当前主要有两种用途：

- 平时就维持一个更保守的热状态
- 配合 `限流等级` 在充电时进入更保守状态

如果打开 `锁定等级`，daemon 会尽量避免在充电 / 停充之间自动来回切换热模拟等级。

#### `加速充电`

它不会提高充电器输出功率。

它做的是：

- 暂时降低设备自身功耗
- 把更多输入功率留给电池

当前子项包括：

- 飞行模式
- Wi-Fi
- 蓝牙
- 降低亮度
- 低电量模式

更适合临时快速补电，不适合长期常开。

### 策略诊断、历史统计与导出

#### 策略诊断

`策略诊断` 当前会集中展示这些真实运行时信息：

- `守护策略`
- `当前状态原因`
- `最近策略切换时间 / 原因`
- `充电命令`
- `系统停充抑制`
- `系统优化充电`
- `由本工具接管`
- `接管前系统状态`
- `协调会话`
- `接管开始时间`
- `最近禁流/恢复时间`

如果你想搞清楚“为什么现在是这个状态”，先看这里。

#### 历史统计

历史统计页当前支持：

- `5 分钟`
- `小时`
- `天`
- `月`

并可按页面切换查看：

- 电量 / 温度
- 电流
- 电压

#### 策略事件时间线

这是另一条独立于曲线统计的持久化事件流。

当前实现里：

- 策略事件持久化到独立 `sqlite` 表
- daemon 中途重启后，最近一段事件尽量保留
- 关闭统计并选择 `删除历史记录` 时，时间线也会一起清掉

#### 导出能力

当前可以导出：

- `复制诊断摘要`
- `导出事件时间线`
- `复制长测校准模板`

## 推荐起手配置

### 场景 1：长期插电办公

建议：

- `停止充电 = 50% ~ 80%`
- `智能停充 = 开`
- 如果你不想让系统接管 100%，就不要打开 `停止电量=100% 时交由系统控制`
- 如果发热明显，再考虑温度控制或轻度限流
- 不建议一开始就开 `停充时启用禁流`

### 场景 2：游戏 / 导航 / 热点 / 录屏

建议：

- `停止充电 = 70% ~ 80%`
- `停充时启用禁流 = 关`
- 如果发热明显，可尝试 `限流等级 = 轻度 / 中度`
- 如果只是临时补电更重要，可以用 `加速充电`

### 场景 3：夜间充电，但偶尔想满电出门

建议：

- 平时正常设置上限
- 用 `满充计划`
- 常见起手值：`每隔天数 = 7`、`开始时间 = 02:00`、`持续时长 = 4 小时`

## 排障建议

如果这次的表现和你的预期不一致：

1. 先看 `策略诊断`
2. 再看 `实时信号`
3. 再看 `供电环境`
4. 最后才调参数

优先排查顺序建议：

1. 先确认 `停止充电` 上限是否合理
2. 再确认 `100% 系统接管` 是否和你的预期一致
3. 再确认是否误开了 `停充时启用禁流`
4. 最后才考虑 `限流 / 高温模拟 / 加速充电`

如果要长期验证，建议配合 [docs/真机长测与阈值校准.md](docs/真机长测与阈值校准.md) 一起用。

## 支持的安装产物

仓库当前脚本会生成这几类发布产物：

- TrollStore：`out/ChargeLimiter_<VERSION>_TrollStore.tipa`
- rootful：`out/ChargeLimiter_<VERSION>_rootful_arm.deb`
- rootless：`out/ChargeLimiter_<VERSION>_rootless_arm64.deb`
- roothide：`out/ChargeLimiter_<VERSION>_roothide_arm64e.deb`

roothide **默认原生构建**：scheme `ChargeLimiter roothide` + 模板 `ChargeLimiter/Package_roothide/`（`THEOS_PACKAGE_SCHEME=roothide`，Architecture `iphoneos-arm64e`，包布局无 `/var/jb`）。
需要 libroothide / roothide 的 `libroot`（见下方构建说明）。从 rootless 转换仅作紧急回滚：`./scripts/build_packages.sh --legacy-roothide-convert`。

## 构建与打包

详细说明见 [构建安装包.md](构建安装包.md) 与 [docs/roothide-packaging.md](docs/roothide-packaging.md)。

快速命令：

```bash
./scripts/build_packages.sh
```

跳过 roothide（本机无 roothide 库时）：

```bash
./scripts/build_packages.sh --skip-roothide
```

手动指定版本号：

```bash
./scripts/build_packages.sh 1.14.0
```

单独验证编译：

```bash
xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter" -destination "generic/platform=iOS" -configuration Release -derivedDataPath build_rootful CODE_SIGNING_ALLOWED=NO ARCHS=arm64
```

```bash
xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter rootless" -destination "generic/platform=iOS" -configuration Release -derivedDataPath build_rootless CODE_SIGNING_ALLOWED=NO ARCHS=arm64
```

```bash
xcodebuild -project ChargeLimiter.xcodeproj -scheme "ChargeLimiter roothide" -destination "generic/platform=iOS" -configuration Release -derivedDataPath build_roothide CODE_SIGNING_ALLOWED=NO ARCHS=arm64 THEOS_PACKAGE_SCHEME=roothide
```

## 相关文档

- [更新日志](CHANGELOG.md)
- [构建安装包.md](构建安装包.md)
- [原生 Roothide 打包说明](docs/roothide-packaging.md)
- [真机长测与频率校准.md](docs/真机长测与频率校准.md)

## 依据

这份 README 以当前仓库源码为主，而不是沿用旧版本的功能说明。

### 代码依据

- [ChargeLimiter/daemon.mm](ChargeLimiter/daemon.mm)
- [ChargeLimiter/utils.mm](ChargeLimiter/utils.mm)
- [ChargeLimiter/UIKit/CLBatteryManager.m](ChargeLimiter/UIKit/CLBatteryManager.m)
- [ChargeLimiter/UIKit/Controllers/CLSettingsViewController.m](ChargeLimiter/UIKit/Controllers/CLSettingsViewController.m)
- [ChargeLimiter/UIKit/Controllers/CLAdvancedSettingsViewController.m](ChargeLimiter/UIKit/Controllers/CLAdvancedSettingsViewController.m)

### Apple 官方资料

- [About Charge Limit and Optimized Battery Charging on iPhone](https://support.apple.com/en-us/108055)
- [Charge and maintain your iPhone battery](https://support.apple.com/en-us/105105)
- [Use Low Power Mode to save battery life on your iPhone or iPad](https://support.apple.com/en-us/101604)
- [If your iPhone or iPad gets too hot or too cold](https://support.apple.com/en-asia/118431)
- [Energy Efficiency Guide for iOS Apps: Minimize Timer Use](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/MinimizeTimerUse.html)
- [Energy Efficiency Guide: Respond to Thermal State Changes](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/RespondToThermalStateChanges.html)
