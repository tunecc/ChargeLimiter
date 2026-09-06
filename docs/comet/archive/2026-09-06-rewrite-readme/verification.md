---
generated_from_state_version: 17
---

# 验证

## 当前结果

- 结果: **已归档**
- 验证情况: **已完成检查，验证结果已确认**
- 目标周期: 1
- 迭代: 2
- 验证器尝试次数: 3
- 完成时间: 2026-09-06T10:39:08.950Z
- 摘要: 最终候选 1aae274 通过全部 9 项验收：diff 仅改 README.md、工作树干净；第 1 轮唯一失败项 A4 已修复且与源码一致，其余 8 项源码逐项核对成立。

## 验收

| 编号 | 结果 | 来源 | 验收项 | 原因 |
| --- | --- | --- | --- | --- |
| A1 | passed | brief.md | A1: README 为中英双语结构：前半为简体中文，后半为 English，两部分章节一一对应且内容对等，文首提供另一语言的锚点跳转链接。 | 中英 14 组章节一一对应，抽查默认阈值 20/80/35/40、14 端点表、配置键表、4 类产物名、URL 表、QQ 群、刷新 4 档逐字一致；#introduction↔#介绍 及文内锚点均有对应标题。 |
| A2 | passed | brief.md | A2: 定位与功能描述以本 fork 现状为准：充电策略调度器（明确非硬件旁路充电）；支持 TrollStore / rootful / rootless / roothide（原生构建）；最低 iOS 13.0；功能总览覆盖 CHANGELOG v1.15.x 的实际功能集（智能停充及回退、停充禁流、限流等级原子配置、满充计划、系统优化充电协调与永久停用、加速充电、策略诊断、历史统计、策略事件时间线、导出、日志级别）。 | 定位为充电策略调度器、四环境（roothide 原生）与 iOS 13.0 对 pbxproj IPHONEOS_DEPLOYMENT_TARGET=13.0 与三份 DEBIAN/control firmware (>= 13.0) 一致；功能总览逐项对上 CHANGELOG v1.15.0–1.15.3。 |
| A3 | passed | brief.md | A3: 上游权威资料已纳入并按本 fork 现状校订：包含 FAQ、电池兼容性测试、品牌新电池激活、充电宝兼容性、停充/禁流/限流名词解释、阈值与 120 秒延迟说明、使用前必看；凡与本 fork 实现冲突处（iOS 版本范围、原生 UIKit 界面而非 WebUI、系统优化充电处理方式、新增功能）以本 fork 为准，不保留过时表述。 | FAQ、电池兼容性测试（120 秒/≥5mA）、品牌激活（11 品牌）、充电宝兼容性、名词解释、阈值偏差与 120 秒延迟、使用前必看全部纳入并按 fork 校订；无 WebUI/MonkeyDev/iOS 12 残留；悬浮窗描述与源码一致（GET 回 405、仅 JSON POST）。 |
| A4 | passed | brief.md | A4: 使用说明与本 fork 实际界面一致：主页面、充电高级（智能停充 / 停止电量=100% 交由系统 / 停充时启用禁流 / 系统优化充电 / 满充计划 / 限流等级 / 高温模拟 Powercuff / 加速充电）、策略诊断、历史统计与策略事件时间线、软件设置（日志级别）；悬浮窗与模式（插电即充 / 边缘触发）按 fork 实际行为描述。 | 主页面/阈值说明/配置键表（中英）明确开始充电行固定隐藏非界面入口，与 CLSettingsViewController.m:5611-5626/:6347-6353/:6671 及 daemon.mm:3033/:3214/:3323 一致；刷新频率为实际 4 档（:4454-4465）；充电高级全部标签取值、策略诊断字段、探针、导出与校准、历史统计四档、日志级别、悬浮窗遗留、模式固定插电即充均与源码吻合。 |
| A5 | passed | brief.md | A5: HTTP API 参考与 `daemon.mm` 实现一致：绑定 127.0.0.1:1230；api 端点集合（get_conf / set_conf / get_bat_info / get_diag / get_policy_events / apply_now / set_charge_status / set_inflow_status / set_limit_inflow_config 等）与配置键名称逐一核对源码，只读项有标注。 | 14 端点对 handleReq（daemon.mm:3463-3811）；配置键表+脚注覆盖 gConf*Keys 全部键，默认值对 initConf；端口 1230 + bindToLocalhost:YES + 仅 POST 405 + mode 强制回写 + 只读键清单 + get_policy_events 默认 200 条均一致。 |
| A6 | passed | brief.md | A6: 快捷指令章节与 `Info.plist` 注册的 URL scheme（`cl`）一致，路径列表与 fork 实际支持的 URL 相符。 | Info.plist 仅注册 cl scheme；ui.mm openURLContexts 支持 charge/nocharge/exit[N]/组合与巨魔 reset_and_exit，与 README URL 表完全相符。 |
| A7 | passed | brief.md | A7: 构建与安装产物章节与仓库脚本一致：四类产物命名（TrollStore `.tipa`、rootful `.deb`、rootless `.deb`、roothide `.deb` 原生构建）、`./scripts/build_packages.sh` 用法（含 `--skip-roothide`、版本号参数）、xcodebuild 验证命令与 AGENTS.md 一致；下载链接指向本 fork 的 GitHub Releases。 | 四类产物命名与 build_packages.sh:375-378 逐字一致；[VERSION] [--skip-roothide] 用法、版本默认取 MARKETING_VERSION；三条 xcodebuild 命令与 AGENTS.md/脚本一致；release.yml on.tags v*；无 --legacy-roothide-convert 残留。 |
| A8 | passed | brief.md | A8: 文档与资源链接有效：README 引用的本地文档路径存在、截图路径存在、Apple 官方资料链接保留；仓库内不存在因重命名产生的失效 `Readme.md` 引用。 | 本地链接目标全部存在（CHANGELOG.md、构建安装包.md、docs/roothide-packaging.md 均被 git 跟踪、screenshots/1-4.PNG、6 个源码文件）；无失效 Readme.md 引用；Apple 官方链接保留。 |
| A9 | passed | brief.md | A9: 保留上游致谢与归属：单独一节注明上游仓库（lich4/ChargeLimiter）及本 fork 与上游的关系，上游社区链接（QQ 群、Telegram）放在该节内。 | 中英致谢/上游归属独立成节；QQ 群 669869453 与 t.me/chargelimiter 全文仅在该节；下载与 Issues 指向 tunecc/ChargeLimiter。 |

## 检查

| 检查 | 命令 | 工作目录 | 状态 | 退出码 | 耗时 |
| --- | --- | --- | --- | ---: | ---: |
| README 本地链接与图片路径存在性 | -c import re,os,sys md=open('README.md',encoding='utf-8').read() miss=[t for t in re.findall(r'\[[^\]]*\]\(([^)#\s]+)[^)]*\)',md) if not t.startswith(('http','mailto:')) and not os.path.exists(t)] miss+=[s for s in re.findall(r'<img src="([^"]+)"',md) if not os.path.exists(s)] if miss: print('MISSING',miss); sys.exit(1) print('ALL_LINK_TARGETS_EXIST') | . | passed | 0 | 23 ms |
| README 内部锚点全部可解析 | -c import re,sys md=open('README.md',encoding='utf-8').read() heads=[] for line in md.splitlines(): m=re.match(r'^(#{1,6})\s+(.*)',line) if m: heads.append(m.group(2).strip()) def gh_anchor(t): t=t.strip().lower(); t=re.sub(r'[^\w\u4e00-\u9fff\- ]','',t); return t.replace(' ','-') anchors={} for h in heads: a=gh_anchor(h); anchors[a]=anchors.get(a,0)+1 bad=[t for t in re.findall(r'\[[^\]]*\]\(#([^)]+)\)',md) if t not in anchors] if bad: print('BAD_ANCHORS',bad); sys.exit(1) print('ALL_ANCHORS_RESOLVE') | . | passed | 0 | 24 ms |
| 旧描述残留检查（刷新档位/开始充电可见性） | -c import sys md=open('README.md',encoding='utf-8').read() bad=[] if '3 分钟 / 5 分钟' in md or '3 min / 5 min' in md: bad.append('stale refresh tiers') if '滑块（10–95）' in md or 'slider (10–95)' in md: bad.append('stale charge-below slider as visible control') if '4 档' not in md and '1 秒 / 20 秒 / 1 分钟 / 10 分钟' not in md: bad.append('missing corrected tiers zh') if '1 s / 20 s / 1 min / 10 min' not in md: bad.append('missing corrected tiers en') if bad: print('STALE',bad); sys.exit(1) print('NO_STALE_DESCRIPTION') | . | passed | 0 | 22 ms |

## 阻塞项

_无。_

## 风险与跳过的工作

- 已知可接受残余：内部键脚注将 lang 归为「无 UI 暴露」，实际由 App 语言设置经 set_conf 同步（CLSettingsViewController.m:4577-4582），措辞瑕疵不影响验收。

## 之前的迭代

| 目标周期 | 迭代 | 尝试 | 结果 | 未解决项 | 摘要 | 完成时间 |
| ---: | ---: | ---: | --- | --- | --- | --- |
| 1 | 1 | 1 | fail | A4 | 候选 e5156fd 是一份高质量的源码级准确双语 README：A1/A2/A3/A5/A6/A7/A8/A9 共 8 项全部通过，端点、配置键、默认值、产物命名、URL scheme、链接均与源码逐一吻合，上游资料校订到位。唯一不达标项是 A4：主页面开始充电滑块实际被无条件隐藏、刷新频率实际仅 4 档，需小幅修订。 | 2026-09-06T10:04:01.501Z |
| 1 | 2 | 1 | execution-error | — | Native Verifier response was invalid: Native Verifier acceptance coverage is invalid (duplicate: none; unknown: A1, A2, A3, A5, A6, A7, A8, A9; missing: none) | 2026-09-06T10:18:59.719Z |
| 1 | 2 | 2 | recovery | — | Repair verification passed for A4; final full verification is required. | 2026-09-06T10:27:58.019Z |
| 1 | 2 | 3 | pass | — | 最终候选 1aae274 通过全部 9 项验收：diff 仅改 README.md、工作树干净；第 1 轮唯一失败项 A4 已修复且与源码一致，其余 8 项源码逐项核对成立。 | 2026-09-06T10:39:08.950Z |



## 结论

最终候选 1aae274 通过全部 9 项验收：diff 仅改 README.md、工作树干净；第 1 轮唯一失败项 A4 已修复且与源码一致，其余 8 项源码逐项核对成立。
