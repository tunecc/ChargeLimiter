# 移动「调试与观测」入口到软件设置设计

## 背景

高级设置页（`CLAdvancedSettingsViewController`）包含一块「调试与观测」卡片，装有两行入口：
`策略诊断`（tag 314，push 到 `CLPolicyDiagnosticsViewController`）和 `日志级别`（picker，normal/error）。

其中「日志级别」本质是配置项（与通知、语言、深色模式同类）；「策略诊断」是诊断维护工具。
两行都放在高级设置里，与充电策略控制（加速充电、满充计划、Smart Charge 协调等）混在同一页，语义不够清晰。

## 目标

1. 把「调试与观测」卡（策略诊断入口 + 日志级别）整体从高级设置移至软件设置页。
2. 只移入口，不搬策略诊断页实现（`CLPolicyDiagnosticsViewController` 留在 `CLAdvancedSettingsViewController.m`）。
3. 保持现有功能零回归：日志级别读取/写入、策略诊断页面跳转、本地化、rollback 语义都不变。

## 非目标

- 不把策略诊断页内容直接铺进软件设置（不做全量搬移）。
- 不重构 `CLPolicyDiagnosticsViewController` 的实现或拆分文件。
- 不改变 `log_level` 配置键、IPC、daemon 刷新链路。
- 不改动高级设置里除「调试与观测」卡以外的任何充电策略卡片。

## 方案（所选）

### 软件设置目标形态

`CLSoftwareSettingsViewController`（`CLSettingsViewController.m` 内，`setupSettingsCard` 方法）：
在「停充预设」之后、「应用数据目录」之前插入两行：

```objc
[self.settingsCard addSeparator];
[self.settingsCard addNavigationRowWithIcon:@"waveform.path.ecg" title:CLL(@"策略诊断") value:CLL(@"查看")
                                       color:[UIColor systemTealColor] target:self action:@selector(softwarePolicyDiagnosticsTapped)];
[self.settingsCard addSeparator];
[self.settingsCard addNavigationRowWithIcon:@"doc.text" title:CLL(@"日志级别") value:[self softwareLogLevelText]
                                       color:[UIColor systemPurpleColor] target:self action:@selector(softwareLogLevelTapped:)];
```

> 说明：`addNavigationRowWithIcon` 是软件设置页现有的行构建 API（`CLSettingsViewController.m:990`），
> 与高级设置的 `addPickerRowWithIcon` 视觉一致（title + value + chevron）。

### 迁移的代码段

从 `CLAdvancedSettingsViewController.m` 迁到 `CLSoftwareSettingsViewController`：

| 段 | 源位置 | 目标实现 |
|----|--------|---------|
| `kLogLevelPickerTag` (=316) | 高级设置常量区 | 软件设置文件内常量 |
| `logLevelText` → `softwareLogLevelText` | `CLAdvancedSettingsViewController.m:2076` | 复制逻辑（读 `getlocalKV_C(@"log_level")`，仅 `error` → 仅错误，其余 → 标准） |
| `logLevelTapped:` → `softwareLogLevelTapped:` | `CLAdvancedSettingsViewController.m:2329` | 复制 action sheet（标准/仅错误/取消，经 `setConfigWithKey:value:completion:` 写入） |
| `policyDiagnosticsTapped` → `softwarePolicyDiagnosticsTapped` | `CLAdvancedSettingsViewController.m:2128` | 复制 push 逻辑 |

### 跨文件引用策略诊断页

`CLPolicyDiagnosticsViewController` 的 `@interface` 定义在 `CLAdvancedSettingsViewController.m:568`（非头文件）。
为避免跨文件直接引用头文件，软件设置页用 `NSClassFromString` 动态创建：

```objc
- (void)softwarePolicyDiagnosticsTapped {
    Class cls = NSClassFromString(@"CLPolicyDiagnosticsViewController");
    UIViewController *vc = [[cls alloc] init];
    if (vc) {
        [self.navigationController pushViewController:vc animated:YES];
    }
}
```

两个文件同属一个 target（`ChargeLimiter`），链接期类符号可用。

### 从高级设置删除

`CLAdvancedSettingsViewController.m` 的 `setupContent` 中删除整块 `diagnosticsCard`：

```objc
CLAdvSettingsCard *diagnosticsCard = [[CLAdvSettingsCard alloc] init];
[diagnosticsCard addSectionHeader:CLL(@"调试与观测")];
[diagnosticsCard addPickerRowWithIcon:@"waveform.path.ecg" title:CLL(@"策略诊断") ... tag:314 ...];
[diagnosticsCard addSeparator];
[diagnosticsCard addPickerRowWithIcon:@"doc.text" title:CLL(@"日志级别") ... tag:kLogLevelPickerTag ...];
[self addTipRowToCard:diagnosticsCard ...];
[self.mainStack addArrangedSubview:diagnosticsCard];
```

同步删除高级设置里随迁的 `logLevelText`、`logLevelTapped:`、`policyDiagnosticsTapped:`、`kLogLevelPickerTag`，
避免死代码（保留 `CLPolicyDiagnosticsViewController` 类本身）。

### 日志级别显示的动态刷新

软件设置页已有 `configDidUpdate`（监听 `CLConfigDidUpdateNotification`，`CLSettingsViewController.m:5177`），
会在配置变更时用 `updateCardValue:` 刷新行的 value 文本。

在 `configDidUpdate` 中追加一行，把「日志级别」行刷新为最新的 `softwareLogLevelText`：

```objc
[self updateCardValue:self.settingsCard title:CLL(@"日志级别") value:[self softwareLogLevelText]];
```

这样选完「仅错误」/「标准」经 daemon 写入成功后，行内 value 立即更新。
`updateCardValue:` 按 title 的 hash 查找行内 UILabel（`CLSettingsViewController.m:4590`），对新增行同样适用。

## 数据流（不变）

```text
软件设置页
  -> setConfigWithKey:@"log_level" value:...   （经 CLAPIClient → daemon IPC）
  -> daemon set_conf -> setLocalString -> 共享 plist + daemon 内缓存刷新
  -> daemon 文件日志按新级别过滤 aldente.log
```

## 本地化

新增行的文案全部复用现有 key：
`策略诊断`、`查看`、`日志级别`、`标准`、`仅错误`、`取消` 均已在 en/zh-Hans 字符串表中存在，无需新增条目。

## 测试设计

### 本地自动验证

- 编译 rootful、rootless、roothide 三个 App scheme，`CODE_SIGNING_ALLOWED=NO` 下 BUILD SUCCEEDED。
- 运行现有 Python 测试套件（`tests/test_*.py`）确认零回归。
- `git diff --check` 无空白错误。
- 高级设置里「日志级别」/「策略诊断」入口已消失；软件设置里新增两行存在（通过读源码确认）。

### 真机验收（可选）

1. 进入软件设置，确认「策略诊断」「日志级别」两行出现在「停充预设」之后。
2. 点「日志级别」切到「仅错误」，重启 daemon，确认 `aldente.log` 过滤用户级启动细节、错误仍写入。
3. 点「策略诊断」，确认仍打开完整诊断页。
4. 点「日志级别」切回「标准」，确认 `listen_ready`/`daemon_started` 恢复可见。

## 完成标准

- 高级设置页不再有「调试与观测」卡；软件设置页出现「策略诊断」「日志级别」两行。
- `log_level` 的读取、写入、IPC、回滚语义与迁移前完全一致。
- 三个 scheme 编译通过，现有测试零回归。
- 高级设置的充电策略卡片（加速/停充/限流/满充计划/Smart Charge）完全不动。
- 策略诊断页 `CLPolicyDiagnosticsViewController` 类保留，跳转行为不变。