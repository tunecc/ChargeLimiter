# Outcome

修复 iOS 17 禁流稳态下 `ExternalConnected` / `ExternalChargeCapable` 由系统间接派生抖动，导致 `isAdaptorNewConnect` 边沿误判、`notifyForChargeCommandTransition` 误发 `noti_start_charge`（"开始充电"通知）的问题。

用户可见表现：息屏充电时触发热控或停充进入禁流后，充电线未动，亮屏却收到"开始充电"通知。原版（iOS ≤16）禁流写 `ExternalConnected=NO` 主动稳态，无此问题；iOS 17 改写 override key 后派生值抖动，问题暴露。

# Scope

- `ChargeLimiter/daemon.mm` 的 `isAdaptorConnect`：禁流态判定从"仅看用户开关 `adv_disable_inflow`"扩展为"看运行时是否真正处于禁流态（`adv_disable_inflow=YES` 或 `g_lastInflowCommandTs` 在近 N 秒内、或上一轮 policy 为 `no_inflow`/`temp_paused` 触发过禁流）"，处于禁流态时统一走 `AdapterDetails["Description"]` 分支，不读 `ExternalChargeCapable`。
- `isAdaptorNewConnect` 边沿判定加禁流态守卫：当前或上一轮处于 inflow disabled 状态时，抑制 false→true 边沿，避免抖动产生伪插电信号。
- `notifyForChargeCommandTransition` 的 `freshPlug` 门禁兜底：禁流态稳态下不单凭 `previousExternalConnected`/`currentExternalConnected` bool 跳变判插电，需结合更稳的信号（`AdapterDetails` 存在且非 `"batt"`，或电流从 ~0 跳到正值）。

# Non-goals

- 不改 iOS 17 禁流的 override key 写法（`FieldDiagsInflowInhibit`/`OBCInflowInhibit` 仍按 [[ios17-charge-control-root-cause]] 探针结论保留）。
- 不改 `setInflowStatus` 的写入路径与回退逻辑。
- 不重构 charge policy 状态机本身，只在边沿判定与通知门禁处加守卫。
- 不修 Relaxin 适配遗留问题（user/501 域偏差等），另起 change。
- 不引入新的用户可见行为或配置项；纯 bug 修复，行为应为"没插线就不提示开始充电"。

# Acceptance examples

- 息屏充电 → 热控触发 `setInflowStatus(NO)`（temp_paused）进入禁流稳态 → 亮屏 → **不**收到 `noti_start_charge` 通知（充电线全程未动）。
- 息屏充电 → 容量到上限触发停充（adv_disable_inflow=YES 路径）进入禁流稳态 → 亮屏 → **不**收到 `noti_start_charge`。
- 禁流稳态下系统周期性刷新 IOKit 属性导致 `ExternalChargeCapable` 短暂 false→true 抖动 → `isAdaptorNewConnect` 不产生边沿 → 不误发通知。
- 禁流稳态下真正拔线 → `AdapterDetails` 消失 → `isAdaptorConnect` 正确返回 NO → 后续重新插电时 `isAdaptorNewConnect` 正常产生边沿 → 正常发 `noti_start_charge`（真插电仍要通知）。
- 非禁流态（正常充电中、未触发任何禁流）→ `isAdaptorConnect` 走原 `ExternalChargeCapable` 路径，行为与原版一致，不回归。
- 热控恢复（temperature_recovered）从 temp_paused 恢复充电 → 仍按原逻辑发 `noti_resume_charge_temperature`，不被禁流态守卫误抑制。

# Constraints and invariants

- `isAdaptorConnect` 在禁流态走 `AdapterDetails` 分支时，`Description` 为 nil 或 `"batt"` 返回 NO，与现有禁流模式分支语义一致。
- 禁流态守卫必须是有界的：一旦检测到真正拔线（`AdapterDetails` 消失或电流持续为 0），守卫解除，恢复对插电边沿的敏感。
- 不引入新配置开关；禁流态判定基于既有 `g_lastInflowCommandTs` / `g_policyState` / `adv_disable_inflow`。
- 改动局限于 `daemon.mm` 三个函数（`isAdaptorConnect` / `isAdaptorNewConnect` / `notifyForChargeCommandTransition` 的 freshPlug 门禁）及其必要的辅助函数，不扩散。
- 不破坏 [[ios-power-re-playbook]] "有效判定用电流阈值 + 只读位图，不单信 IsCharging 类 bool" 原则。

# Decisions

- 采用 memory `ios17-inflow-external-connected-flicker` 的修复方向 1+2：`isAdaptorConnect` 禁流态统一走 `AdapterDetails` 分支（方向1）+ `freshPlug` 通知门禁兜底（方向2）。理由：1 让 `isAdaptorConnect` 在禁流态稳定消除抖动源，2 作为通知门禁兜底防止边沿抖动漏到通知层。
- 禁流态判定用**语义判定**而非纯时间窗口：`adv_disable_inflow=YES` 或 `g_policyState` 为禁流相关态（`no_inflow`/`temp_paused`）时视为禁流态，与既有 `isInflowRuntimeLikelyDisabled` 口径对齐，避免新增不一致判定。不引入 `g_lastInflowCommandTs` 时间窗口常量（抖动是稳态派生行为，只要 policy 还在禁流态就持续抑制；真正拔线由 `AdapterDetails` 消失检测，脱离时间窗口）。
- 守卫解除条件：`AdapterDetails` 消失或 `Description` 变为 `"batt"`/nil → 视为真拔线，守卫解除，恢复对后续插电边沿的敏感。这样真拔线→插电通知不回归。

# Open questions

- [blocking] CONFIRM: 共享理解确认——目标为修复 iOS 17 禁流态 `ExternalConnected`/`ExternalChargeCapable` 派生抖动误发"开始充电"通知；范围限 `daemon.mm` 的 `isAdaptorConnect`/`isAdaptorNewConnect`/`notifyForChargeCommandTransition`（freshPlug 门禁）；用语义判定禁流态、`AdapterDetails` 消失作守卫解除；不引入新配置/不改 override key 写法；验收场景 1-6 逐项真机验证。

# Verification expectations

- 源码层面：`isAdaptorConnect` 在禁流态不读 `ExternalChargeCapable`；`isAdaptorNewConnect` 在禁流稳态不产生伪边沿；`freshPlug` 门禁在禁流态抑制误通知。编译通过，无新增警告。
- 真机验收（iPhone 15 Pro Max / iOS 17.1）：场景 1-6 逐项验证，重点抓禁流稳态下 `ExternalConnected`/`ExternalChargeCapable` 抖动时序与通知触发日志，确认误发通知消除且真插电/热控恢复通知不回归。
- 沿用 [[ios-power-re-playbook]] 探针方法论：用电流阈值 + `AdapterDetails` 只读位图作有效判据，bool 跳变不作边沿判据。
