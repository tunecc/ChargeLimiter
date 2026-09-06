# 目标

整体重写本仓库的 README（git 中现为 `Readme.md`，重写后统一为 `README.md`），使其准确反映本 fork（tunecc/ChargeLimiter，v1.15.3）的现状，并吸收上游（lich4/ChargeLimiter）手写 README 中的权威新用户学习资料，形成一份中英双语、可支撑新用户从了解到上手再到排障的完整项目说明。

# 范围

- 仅重写 README 文件本身（`Readme.md` → `README.md`），中英双语，前中文后 English，内容对等。
- 内容来源与优先级：本 fork 源码与 CHANGELOG（现状为准）+ 上游 README 权威资料（校订后吸收）。
- 吸收的上游资料（按本 fork 现状校订）：常见问题 FAQ、电池兼容性测试方法（120 秒测试 / ≥5mA 判定）、品牌新电池激活方法、充电宝兼容性、停充/禁流/限流名词解释、阈值设定与 120 秒延迟偏差说明、使用前必看、已知问题。
- 按本 fork 现状撰写的章节：项目定位（充电策略调度器，非硬件旁路）、功能总览（智能停充、停充禁流、限流等级、满充计划、系统优化充电协调、加速充电、策略诊断、历史统计与策略事件时间线、导出、日志级别等）、使用说明（主页面、充电高级、软件设置、悬浮窗、模式）、快捷指令（`cl://`）、HTTP API 参考（端口 1230，端点与配置键以 `daemon.mm` 实现为准）、构建与打包、安装产物、排障建议。
- 同步修正仓库内对 README 文件名的引用（构建脚本、文档中如引用 `Readme.md` 则更新为 `README.md`）。

# 非目标

- 不改动任何源码、构建脚本行为或打包模板（仅允许同步 README 文件名引用的文案）。
- 不重写 `docs/` 与根目录下的其他文档（`构建安装包.md`、`CHANGELOG.md`、`docs/真机长测与阈值校准.md` 等），只保证 README 中的链接指向有效路径。
- 不新增截图，复用仓库现有 `screenshots/` 资源。
- 不更新 `lang.json` / UI 文案 / 翻译资源。
- 不做版本发布、不更新 CHANGELOG。

# 验收示例

- A1: README 为中英双语结构：前半为简体中文，后半为 English，两部分章节一一对应且内容对等，文首提供另一语言的锚点跳转链接。
- A2: 定位与功能描述以本 fork 现状为准：充电策略调度器（明确非硬件旁路充电）；支持 TrollStore / rootful / rootless / roothide（原生构建）；最低 iOS 13.0；功能总览覆盖 CHANGELOG v1.15.x 的实际功能集（智能停充及回退、停充禁流、限流等级原子配置、满充计划、系统优化充电协调与永久停用、加速充电、策略诊断、历史统计、策略事件时间线、导出、日志级别）。
- A3: 上游权威资料已纳入并按本 fork 现状校订：包含 FAQ、电池兼容性测试、品牌新电池激活、充电宝兼容性、停充/禁流/限流名词解释、阈值与 120 秒延迟说明、使用前必看；凡与本 fork 实现冲突处（iOS 版本范围、原生 UIKit 界面而非 WebUI、系统优化充电处理方式、新增功能）以本 fork 为准，不保留过时表述。
- A4: 使用说明与本 fork 实际界面一致：主页面、充电高级（智能停充 / 停止电量=100% 交由系统 / 停充时启用禁流 / 系统优化充电 / 满充计划 / 限流等级 / 高温模拟 Powercuff / 加速充电）、策略诊断、历史统计与策略事件时间线、软件设置（日志级别）；悬浮窗与模式（插电即充 / 边缘触发）按 fork 实际行为描述。
- A5: HTTP API 参考与 `daemon.mm` 实现一致：绑定 127.0.0.1:1230；api 端点集合（get_conf / set_conf / get_bat_info / get_diag / get_policy_events / apply_now / set_charge_status / set_inflow_status / set_limit_inflow_config 等）与配置键名称逐一核对源码，只读项有标注。
- A6: 快捷指令章节与 `Info.plist` 注册的 URL scheme（`cl`）一致，路径列表与 fork 实际支持的 URL 相符。
- A7: 构建与安装产物章节与仓库脚本一致：四类产物命名（TrollStore `.tipa`、rootful `.deb`、rootless `.deb`、roothide `.deb` 原生构建）、`./scripts/build_packages.sh` 用法（含 `--skip-roothide`、版本号参数）、xcodebuild 验证命令与 AGENTS.md 一致；下载链接指向本 fork 的 GitHub Releases。
- A8: 文档与资源链接有效：README 引用的本地文档路径存在、截图路径存在、Apple 官方资料链接保留；仓库内不存在因重命名产生的失效 `Readme.md` 引用。
- A9: 保留上游致谢与归属：单独一节注明上游仓库（lich4/ChargeLimiter）及本 fork 与上游的关系，上游社区链接（QQ 群、Telegram）放在该节内。

# 约束与不变量

- 与本 fork 实现冲突时一律以本 fork 为准；上游内容仅作权威知识来源，不照搬过时信息（如 iOS 12 支持、WebUI 路径 `www/lang.json`）。
- 版本号、包标识不写死为可能过期的具体值（以占位或"当前版本"表述）。
- 不引入新的硬编码本地路径；不提交 `out/`、`build_*/` 等产物路径引用。
- Markdown 保持 GitHub 渲染兼容（锚点、表格、代码块）。

# 决策

- D1 工作区隔离采用 worktree（用户选择）：已有另一 active change（fix-lockscreen-current-limit），避免相互干扰。
- D2 语言形态为中英双语（用户选择）：跟随上游权威 README 的形态，前中文后 English，两部分对等。
- D3 上游权威资料全量吸收（用户选择）：FAQ、电池兼容性测试、品牌电池激活、充电宝兼容性、名词解释、API 表等全部纳入并按本 fork 现状校订；README 允许较长。
- D4 下载/安装链接指向本 fork 的 GitHub Releases；上游社区链接（QQ 群 669869453、Telegram t.me/chargelimiter）仅放在致谢/上游归属一节。
- D5 文件由 `Readme.md` 重命名为 `README.md`（GitHub 惯例，AGENTS.md 亦以 README.md 称呼），并同步仓库内引用。
- D6 冲突裁决规则：本 fork 实现优先于上游描述；上游特有且本 fork 已不存在的路径（如 WebUI 调试链接、MonkeyDev 编译方式）不纳入编译章节，编译章节以本仓库脚本与 xcodebuild 为准。

# 待解决问题

（无——用户已确认目标、范围、关键决定、验收项与非目标。）

# 验证预期

- 以源码事实核对 README 内容：配置键/端点对 `daemon.mm`、URL scheme 对 `Info.plist`、产物命名对 `scripts/build_packages.sh`、最低 iOS 对 `project.pbxproj` 的 `IPHONEOS_DEPLOYMENT_TARGET`。
- 链接检查：README 内引用的本地路径逐一验证存在。
- 双语对等性检查：中英两部分章节标题一一对应。
- 中文部分为验收主对象（change 语言为 zh-CN）；English 部分检查其与中文章节的结构对等与关键事实一致。
