---
name: diagnostics-panel
description: 策略诊断页增强:一键复制完整诊断、环境与连通性卡片、按钮混淆消除
metadata:
  type: design
  originSessionId: current
  modified: 2026-08-04T10:05:00.000Z
---

# 策略诊断页增强:一键复制完整诊断设计方案

## 1. 背景

用户反映部分设备(iOS 17.0 roothide)安装后不显示电池数据。已有"策略诊断"页面(`CLPolicyDiagnosticsViewController`)展示策略运行时/保持诊断/实时信号/停充控制探针等,但缺少以下能力:

- 诊断信息分散,没有一键复制给开发者的入口
- 缺乏"环境与连通性"信息(越狱类型/包架构/daemon是否在线/读电量service命中情况/IOKit发布key清单)
- 现有导出按钮(`复制探针结果`/`复制诊断摘要`/`复制长测校准模板`/`导出事件时间线`)功能边界不清,容易混淆

目标:在策略诊断页内新增"一键复制完整诊断"入口与"环境与连通性"卡片,消除混淆,让用户能一键复制完整诊断信息给开发者。

## 2. 架构概览

```
策略诊断页 (CLPolicyDiagnosticsViewController)
  ├── [顶部新增] 主按钮 "一键复制完整诊断"  ← 触发拼装+复制
  ├── [新增卡片] 环境与连通性
  │     进页即拉 get_diag + get_conf,实时展示:
  │       环境: iOS版本/设备型号/App版本/包架构/越狱类型/jbroot路径/roothide库加载
  │       连通性: daemon在线/HTTP可达/daemon启动时长/上次拉取错误码
  │       读电量链路: 命中service名/发布key清单/缺失关键key/IOKit错误
  ├── 策略运行时(保留)
  ├── 保持诊断(保留)
  ├── 实时信号(保留)
  ├── 供电环境(保留)
  ├── 最近策略切换(保留)
  ├── 长时间事件时间线(保留)
  ├── 停充控制探针 → 改名+副标题(保留)
  └── 导出与校准 → 改名+副标题(保留,删"复制长测校准模板")
```

## 3. 组件拆分

### U1: `CLDiagnosticCollector`(新文件,App/UIKit下)

纯函数采集器,职责:
- 并行调 `get_diag`(daemon 侧只读自检)+ `get_bat_info`(已有,用 manager 缓存)+ 本地补环境信息
- 组装成结构化 `CLDiagnosticReport` 模型对象
- `- (NSString *)markdownText` 格式化 Markdown 文本
- 不碰 UI,不依赖 UIKit,可纯函数自测

模型 `CLDiagnosticReport`:
- `@property environment: CLDiagEnvironment*` — 环境信息
- `@property connectivity: CLDiagConnectivity*` — 连通性
- `@property batteryProbe: CLDiagBatteryProbe*` — 读电量链路
- `@property policySnapshot: NSDictionary` — 现有策略信号(复用 manager 缓存)
- `@property probeSummary: NSString?` — 探针结论(若有)
- `- (NSString *)markdownText` — 唯一格式化出口

### U2: daemon `get_diag` API(daemon.mm 新增端点 + `getIOPMPSServDiagnostics()`)

只读自检函数,bez:
- 命中 service 名(AppleSmartBattery / IOPMPowerSource / 未匹配)
- 发布 key 清单(一次 IORegistryEntryCreateCFProperties 列所有 key)
- 5 个关键 key 存在性:CurrentCapacity/Amperage/Voltage/IsCharging/Temperature
- IORegistryCreateCFProperties 返回值
- serv_boot(daemon 启动时间戳)
- use_smart bool
- 越狱库加载标记:libjailbreak.dylib dlopen 成败

**硬约束:纯只读,无副作用**。不 SetCFProperties、不 exit、不 kill、不重启 daemon、不改变 g_use_smart 缓存、不写文件。

### U3: UI 接入(CLAdvancedSettingsViewController.m 改)

- 在 `CLPolicyDiagnosticsViewController.setupContent` 顶部加"一键复制完整诊断"主按钮
- 新增"环境与连通性"卡片,进页/点复制时实时拉取 U1 填充
- 旧按钮改名+加副标题消除混淆
- 不直接调 daemon HTTP,只经 U1;不自己做采集逻辑

## 4. 复制内容格式(Markdown 分段)

### `# 环境`(App 本地,不依赖 daemon)

```
设备型号:        iPhone15,3
iOS 版本:        17.0
App 版本:        1.14.0
包架构:          roothide
越狱类型:        roothide
jbroot 路径:     /var/containers/.../.jbroot-XXX
上次启动:        2026-08-04 09:00:00
```

### `# 连通性`

```
daemon 在线:     YES
HTTP 可达:       YES
daemon 启动时长: 服务已运行 3h 12m
最近 API 错误码: 0
```

### `# 读电量链路`(daemon get_diag 独家提供)

```
命中 service:    AppleSmartBattery
发布 key 清单:   Amperage,AppleRawCurrentCapacity,CurrentCapacity,...
关键 key 是否齐全:
  CurrentCapacity:      YES
  Amperage:             YES
  Voltage:              YES
  IsCharging:           YES
  Temperature:          YES
IOKit 返回值:     0
use_smart:        1
越狱库加载:
  libjailbreak.dylib:  OK
  libroothide.dylib:   OK
```

### `# 策略信号`(复用现有,截断到 24 行)

### 末尾:若 `lastProbeSummaryText` 非空,附 `## 停充控制探针结论`

## 5. 混淆按钮处理

| 按钮 | 处理 |
|---|---|
| 运行停充控制探针 | 保留不变 |
| 复制探针结果 | 改名 "复制探针→详细" + 副标题"仅含探针结论,不含环境" |
| 复制诊断摘要 | 改名 "复制策略信号" + 副标题"仅含策略/保持/信号,不含环境" |
| 导出事件时间线 | 改名 "导出事件时间线→原始" + 副标题"仅含持久化事件,不含环境" |
| 复制长测校准模板 | 删除(空模板,与诊断无关) |

## 6. 错误处理与降级

- 单字段级降级:每个字段失败填 `(无法获取)`,不抛异常
- daemon 离线时:环境段仍完整,连通性标 NO,读电量链路标 daemon 离线,复制文本照样产出
- 产出文本开头用 `⚠️ daemon 离线` 显眼标记
- get_diag 内 @try/@catch 包裹每个子项,返回值结构体缺啥补啥
- 不传原始 IORegistry 全字典,不回敏感字段(序列号/UDID/完整 jbroot)

## 7. 安全边界

- 复制文本不包含:电池序列号、设备 UDID、jbroot 完整路径只截到 `.jbroot-XXX` 前缀、用户配置类字段
- get_diag 不回原始 IORegistry 全字典,只回 key 名清单 + 5 个关键 key 存在性
- 所有 IOKit 读操作只读,不写

## 8. 测试

- U1 纯函数自测:fixture report → markdownText 断言,固定快照对比
- U2 副作用扫描:Python grep 确认 getIOPMPSServDiagnostics 不含 SetCFProperties/exit/kill
- 分层回归:U1 不直接调 daemon HTTP(只经 CLAPIClient)、U3 不做采集(只调 U1)

## 9. 本地化

新增约 12 个 CLL 键:卡片标题"环境与连通性"、各诊断行标题"命中 service" / "发布 key 清单" / "关键 key 是否齐全" / "越狱库加载" / "daemon 启动时长" / "最近 API 错误码"、主按钮名"一键复制完整诊断"、"已复制"提示。两份 Localizable.strings 加对应翻译。

## 10. 落地分工

### 我写(源码 + 测试 + 文档)

- `CLDiagnosticCollector.h/.m`(U1 全部源码 + CLDiagnosticReport 模型)
- daemon.mm 内 `getIOPMPSServDiagnostics()` + `get_diag` API 端点(U2)
- CLAdvancedSettingsViewController.m 内 UI 接入(U3)
- 新增 Localizable.strings 键值(zh-Hans + en)
- 纯函数自测 + Python 扫描测试

### 用户在能跑 xcodebuild 的环境做

1. 新文件 `CLDiagnosticCollector.h/.m` 加入 App 两个 target(ChargeLimiter / ChargeLimiter_roothide / ChargeLimiter_rootless;daemon 不链接)——同 CLLocalization.m 拆分方式
2. 各 scheme target 的 Preprocessor Definitions 加:
   - roothide target: `CL_PACKAGE_ROOTHIDE=1`
   - rootless target: `CL_PACKAGE_ROOTLESS=2`
   - rootful: 不定义(默认 0)
3. 我提供精确 pbxproj 改动脚本 + 行号说明

## 11. 设计决策记录

| 决策 | 选择 | 理由 |
|---|---|---|
| 采集方式 | 新增 get_diag 端点 | 信息密度最高,一次拿到关键 key 清单 |
| 采集时机 | 进页+点复制都拉 | 实时展示,用户直觉 |
| 复制格式 | Markdown 分段键值 | 人机两用,一眼可读+脚本可提取 |
| 包架构识别 | 编译宏 | 二进制确定,不改运行时 |
| 混淆按钮处理 | 改名+副标题,不删功能 | 保留所有功能,消除混淆 |
| 诊断面板定位 | 策略诊断页内加强 | 不新建页面,复用已有容器 |