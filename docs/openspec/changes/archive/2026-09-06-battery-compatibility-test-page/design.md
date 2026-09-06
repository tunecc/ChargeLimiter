# 设计：电池兼容性测试页面

## Context

- App（UI 进程）与 daemon 通过 `127.0.0.1:1230` HTTP API 通信；`CLAPIClient` 已封装 `setChargeStatus`、`setInflowStatus`、`getBatteryInfo`、`runChargeControlProbe`，daemon 端实现均已就绪，本次不新增、不修改 daemon API。
- `CLBatteryManager` 提供电池实时数据（`amperage`、`instantAmperage`、`isCharging`、`externalConnected` 等）与配置项读写；全局刷新频率跟随用户设置。
- 主页面 `CLSettingsViewController` 的"更多功能"区现有入口为：历史统计 → 充电高级 → 软件设置；入口卡片模式统一（CLGlassCard + UIControl + 推入导航栈）。
- README 手动测试流程定义了判定规则：120 秒内状态变化则支持；之后持续电池电流 ≥5mA 则无法支持；停充与禁流均不支持则设备不被 CL 支持。
- 动机与范围见 proposal.md；行为需求见 specs/battery-compatibility-test/spec.md。

## Goals / Non-Goals

**Goals**

- UI 进程内实现测试编排状态机，零 daemon 改动即可跑通三项测试。
- 测试期间采样节奏与全局刷新频率解耦，保证判定数据稳定。
- 任何退出路径（完成/取消/返回）都恢复测试前配置。

**Non-Goals**

- 不修改 daemon 充电控制逻辑与写法（探针仍是诊断面，不参与判定）。
- 不做后台持续监控或定期自动复测；测试仅由用户手动触发。
- 不替代 README 手动流程文档（页面提示保持精简）。

## Decisions

1. **编排状态机放在 UI 进程（新控制器内），不新增 daemon API。**
   备选：daemon 新增 `battery_compat_test` API 由 daemon 编排。否决理由：daemon 是常驻进程，测试逻辑出错会威胁主功能；HTTP API 已满足全部控制与取数需求；UI 侧实现便于展示实时进度且失败可随时退出。

2. **测试期间由测试控制器独立定时轮询 `getBatteryInfoWithCompletion`（约 1 秒间隔），不依赖 `CLBatteryInfoDidUpdateNotification`。**
   备选：复用 CLBatteryManager 全局刷新通知。否决理由：全局刷新频率用户可调（可能数秒一跳），测试判定需要稳定采样节奏；独立轮询不影响用户设置。

3. **"持续 ≥5mA"判定采用滑动窗口**：状态变化后继续观察一小段确认窗口（候选 10 秒），窗口内电流持续 ≥5mA 才判不支持，避免瞬时抖动误判。具体窗口参数在 design 阶段 Design Doc 定稿。

4. **配置快照/恢复走现有配置保存通道**：测试开始前记录受影响配置快照（至少全局开关、智能停充；插电保持等可能干扰判定的策略项在 Design Doc 定稿），测试序列按项切换，`finally` 语义恢复——完成、取消、离开页面三条路径都执行恢复。

5. **早停规则**：出现状态变化后，若确认窗口内电流低于阈值 → 立即判"支持"并进入下一项；120 秒仍无状态变化 → 判"不支持"；状态变化但电流持续 ≥5mA → 判"不支持"。

6. **前置检查**：未插电、daemon 不在线、电量接近满（停充测试无从生效）时阻止开始并提示。具体阈值在 Design Doc 定稿。

7. **页面结构**：说明区（精简版兼容性说明）→ 测试项选择区 → 开始/取消按钮 → 进度区（当前项、已用时、实时电流）→ 结果区（分项结论 + 最大/最低电流 + 总体判定）→ 探针按钮区。入口卡片复用历史统计入口的视觉模式。

## Risks / Trade-offs

- [测试期间真实停充/禁流，设备最多 6 分钟不受 CL 控制] → 每项 120 秒上限 + 早停；全程可取消；恢复路径幂等。
- [用户测试中途强杀 App，配置恢复未执行] → 恢复操作在每次配置切换前就持久化快照；下次进入测试页可检测残留快照并提示恢复。
- [满电/极低电量状态下测试无意义或误判] → 前置检查排除。
- [禁流态下 `ExternalConnected` 等派生值抖动] → 判定不依赖单一属性，以电流特征 + 状态变化组合判定（Design Doc 细化）。

## Migration Plan

纯新增功能，无数据迁移；发布后即可用，回滚即移除入口与新文件。

## Open Questions

- 滑动确认窗口时长、恢复配置完整清单、满电判定阈值——在 design 阶段 Design Doc 定稿，不影响本设计方向。
