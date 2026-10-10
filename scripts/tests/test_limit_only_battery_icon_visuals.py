"""仅限流电池图标视觉（limit-only-battery-icon-visuals）合约测试

这一组断言存在的原因：主页模拟电池图标（CLBatteryStatusView）的绿色横杆在仅限流模式下
"赖着不走"，根因是两层——① daemon 失败分支提前 return、不发电池事件通知，图标根本不刷新；
② 视觉推导链读 policyState/amperage，而这两个字段在仅限流模式下已停止更新。修好后如果没有
合约守着，任何一次"把 limitOnly 分支挪到推导链后面"或"把补发通知收回 refreshDirectSessionState"
的重构都会让缺陷静默回归（后者还会引入 batteryInfoDidUpdate → refreshDirectSessionState 递归）。

写法纪律（都是被变异测试咬过之后补的，见各 helper 的 docstring）：

- 断言锚定到具体方法体，不用整文件 substring；
- 门控必须按**花括号配平**取块，不能"从 if 往下抓到某个 return"——后者会把语句挪到 if
  之外也判通过（实测变异：视觉短路整体移出门控 → 所有模式都返回限流态，旧写法放行）；
- 比对色值前先剥注释，且允许经临时变量中转——否则注释里提一句字段名、或把赋值拆成两行，
  测试就会假失败，挡住合理重构。
"""

import re
import unittest

from _helpers import source_for

VC = source_for("ChargeLimiter/UIKit/Controllers/CLSettingsViewController.m")
MANAGER = source_for("ChargeLimiter/UIKit/CLBatteryManager.m")

# 档位 → 期望填充主色。与 brief D3 / spec 配色矩阵逐字对应。
LEVEL_COLORS = {
    "LimitOnlyOff": "systemIndigoColor",
    "LimitOnlyNominal": "systemTealColor",
    "LimitOnlyLight": "systemYellowColor",
    "LimitOnlyModerate": "systemOrangeColor",
    "LimitOnlyHeavy": "systemRedColor",
}

# 档位 → 未插电充电时的状态图标（插电充电时段统一 bolt.fill）。
LEVEL_ICONS = {
    "LimitOnlyOff": "tortoise.fill",
    "LimitOnlyNominal": "thermometer.low",
    "LimitOnlyLight": "thermometer.medium",
    "LimitOnlyModerate": "thermometer.sun",
    "LimitOnlyHeavy": "flame.fill",
}

# 档位 → 档位名查表里的键与中文名。
LEVEL_NAMES = {
    "nominal": "正常",
    "light": "轻度",
    "moderate": "中度",
    "heavy": "重度",
}

# 轻/中/重的流动时长与基准不透明度。档位越高流速越快、越明显。
FLOW_PARAMS = {
    "LimitOnlyLight": (2.6, 0.30),
    "LimitOnlyModerate": (1.8, 0.40),
    "LimitOnlyHeavy": (1.2, 0.50),
}

# 既有八个状态的期望主色 / 状态图标 / 是否播循环动画。与本次改动前的实现逐字对应。
EXISTING_STATES = {
    "IdleNormal": ("systemGreenColor", None, "cl.gloss"),
    "Charging": ("systemGreenColor", "bolt.fill", "cl.flow"),
    "LowBattery": (None, None, "cl.lowBatteryPulse"),  # 主色随电量分叉，单独断言
    "Paused": ("systemBlueColor", "pause.fill", None),
    "Hold": ("systemTealColor", "pause.circle.fill", None),
    "HoldRecharge": ("systemGreenColor", "bolt.fill", "cl.flow"),
    "TempPaused": ("systemOrangeColor", "thermometer.sun", "cl.temperature"),
    "NoInflow": ("systemGrayColor", "slash.circle.fill", None),
}


def strip_comments(text: str) -> str:
    """剥掉 // 与 /* */ 注释。

    两个方向都需要：注释里出现被禁字段名会让"不得读 amperage"这类断言假失败；
    反过来把语句注掉也不会让代码消失，但会让"块内应有某语句"的断言失去意义。
    """
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def method_body(source: str, signature: str) -> str:
    """按签名取方法体；签名在 @interface 里也出现一次，取 @implementation 那一处。

    源码里的方法签名常跨多行，因此把签名里的连续空白换成 \\s+ 再匹配。
    """
    pattern = re.compile(r"\s+".join(re.escape(tok) for tok in signature.split()))
    matches = list(pattern.finditer(source))
    if not matches:
        raise AssertionError(f"signature not found: {signature}")
    # 最后一个匹配点是实现（接口声明在前）
    start = matches[-1].start()
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"unterminated method: {signature}")


def gate_regex(condition: str):
    """匹配干净的 `if (<condition>)`。

    刻意**不**把常量短路（`NO &&`、`0 &&`、`false &&`）写成可选项：那些写法下语句仍在源码里，
    只做"字符串存在"断言的会全绿，但运行时永不执行（实测变异漏过）。
    """
    return re.compile(r"if\s*\(\(?\s*" + condition + r"\s*\)?\s*\)")


def if_block(body: str, condition: str, label: str) -> str:
    """按**花括号配平**取出门控块体；门控缺失或被常量短路时直接失败。

    为什么不能近似界定：早期版本用"从 if 的位置取到方法尾/下一个 return"，把块内的语句
    整段挪到 if 之外仍然取得到，断言照过。实测变异 M39——把
    `if (manager.operationMode == CLOperationModeLimitOnly) { return ...; }`
    改成先 return 再判断——会让**所有模式**都返回限流态，而旧 helper 放行。

    另外要求门控后**紧跟 `{`**：`if (cond) ;` 这种把语句提出块外的写法（M36–M43 一族）
    会让"无花括号"分支取到那个孤立分号、块体为空，从而放过"块内应有某语句"的断言。
    """
    body = strip_comments(body)
    gate = gate_regex(condition).search(body)
    if gate is None:
        raise AssertionError(f"{label} 的门控条件缺失或被常量假值短路")
    rest = body[gate.end():]
    offset = 0
    while offset < len(rest) and rest[offset].isspace():
        offset += 1
    if offset >= len(rest):
        raise AssertionError(f"{label} 的门控后面没有语句")
    if rest[offset] != "{":
        raise AssertionError(
            f"{label} 的门控没有紧跟 {{：语句可能已被挪到块外（if (cond) ; 写法）"
        )
    depth = 0
    for index in range(offset, len(rest)):
        if rest[index] == "{":
            depth += 1
        elif rest[index] == "}":
            depth -= 1
            if depth == 0:
                return rest[offset + 1:index]
    raise AssertionError(f"{label} 的门控块没有闭合")


def case_block(body: str, case_name: str) -> str:
    """取 switch 里某个 case 的片段。

    连续堆叠的 `case A: case B:` 之间没有语句，必须合并成同一组，否则取到的片段是空的
    （fall-through 分组在本仓库的 switch 里很常见）。
    """
    labels = [
        (m.start(), m.group(0))
        for m in re.finditer(r"\bcase [A-Za-z0-9_]+:|\bdefault:", body)
    ]
    target = f"case {case_name}:"
    idx = next((i for i, (_, lab) in enumerate(labels) if lab == target), None)
    if idx is None:
        raise AssertionError(f"case not found: {case_name}")
    end = idx + 1
    while end < len(labels):
        between = body[labels[end - 1][0] + len(labels[end - 1][1]):labels[end][0]]
        if between.strip():
            break
        end += 1
    start = labels[idx][0]
    stop = labels[end][0] if end < len(labels) else len(body)
    return body[start:stop]


def primary_colors(block: str):
    """解析块最终赋给 primaryColor 的系统色名，容忍经临时变量中转。

    只对整个块做 assertIn 是不够的：secondaryColor / glossColor 行会引用同一个色值，把
    primaryColor 改成同色系他色时整块仍"包含"期望色（实测变异漏过）。反过来，把赋值拆成
    `UIColor *c = [UIColor systemRedColor]; primaryColor = c;` 也应当算对——所以这里做一次
    别名解析，而不是死盯 `primaryColor = [UIColor ...]` 这一种写法。

    扫描用全文 finditer 而不是逐行：别名与使用可能写在同一行（`{ UIColor *x = ...; p = x; }`）。
    别名模式要容忍 `[UIColor systemXColor]` 这种带接收者的写法——只写 `[systemXColor]`
    会漏掉仓库里最常见的构造形式。
    """
    block = strip_comments(block)
    aliases = {
        m.group(1): m.group(2)
        for m in re.finditer(
            r"UIColor\s*\*\s*(\w+)\s*=\s*(?:\[\s*[A-Za-z]\w*\s+)?(system\w+Color)\s*\]?\s*;",
            block,
        )
    }
    found = []
    for m in re.finditer(r"primaryColor\s*=\s*([^;]+);", block):
        rhs = m.group(1)
        direct = re.search(r"(system\w+Color)", rhs)
        if direct:
            found.append(direct.group(1))
            continue
        alias = re.match(r"\s*(\w+)\s*$", rhs)
        if alias and alias.group(1) in aliases:
            found.append(aliases[alias.group(1)])
    return found


def flow_params_of(body: str, case_name: str):
    """从 startFlowAnimationWithDuration:X opacity:Y 调用里取出时长与不透明度。"""
    block = case_block(body, case_name)
    m = re.search(
        r"startFlowAnimationWithDuration:\s*([0-9.]+)\s*opacity:\s*([0-9.]+)", block
    )
    if not m:
        return None
    return float(m.group(1)), float(m.group(2))


class EnumAndJudgementTests(unittest.TestCase):
    """枚举与判据：仅限流态必须存在，判据只读仅限流自有事实源，且短路必须先于 daemon 链。"""

    def test_limit_only_states_appended_after_existing_eight(self):
        # 既有八态的数值与顺序不能被改动，否则其他模式的视觉会整体错位
        order = [
            "CLBatteryVisualStateIdleNormal = 0",
            "CLBatteryVisualStateCharging",
            "CLBatteryVisualStateLowBattery",
            "CLBatteryVisualStatePaused",
            "CLBatteryVisualStateHold",
            "CLBatteryVisualStateHoldRecharge",
            "CLBatteryVisualStateTempPaused",
            "CLBatteryVisualStateNoInflow",
        ]
        cursor = -1
        for token in order:
            cursor = VC.find(token, cursor + 1)
            self.assertGreater(cursor, -1, f"缺少既有状态 {token}")
        for name in LEVEL_COLORS:
            self.assertGreater(
                VC.find(name),
                VC.find("CLBatteryVisualStateNoInflow"),
                f"{name} 必须追加在既有八态之后",
            )
        # 仅限流态必须是连续的一段，区间常量才成立
        first = VC.find("CLBatteryVisualStateLimitOnlyOff,")
        last = VC.find("CLBatteryVisualStateLimitOnlyHeavy")
        between = VC[first:last]
        for name in list(LEVEL_COLORS)[1:-1]:
            self.assertIn(name + ",", between, f"{name} 应位于仅限流态区间内")

    def test_visual_state_short_circuits_before_daemon_chain(self):
        body = method_body(
            VC, "- (CLBatteryVisualState)visualStateForManager:(CLBatteryManager *)manager"
        )
        branch = if_block(
            body,
            r"manager\.operationMode\s*==\s*CLOperationModeLimitOnly",
            "visualStateForManager: 的仅限流短路",
        )
        self.assertIn(
            "limitOnlyVisualStateForManager:",
            branch,
            "仅限流分支必须真的返回限流态；把 return 挪出门控会被这里抓到",
        )
        # 短路判断必须早于 daemon 推导链，否则陈旧 policyState 仍然先生效
        gate_at = body.find("CLOperationModeLimitOnly")
        derive_at = body.find("CLDisplayedPowerStateForManager")
        self.assertGreater(derive_at, -1, "应仍保留 daemon 推导链供其他模式使用")
        self.assertLess(gate_at, derive_at, "仅限流短路判断必须先于 daemon 推导链")

    def test_limit_only_judgement_uses_no_daemon_only_fields(self):
        body = strip_comments(
            method_body(
                VC,
                "- (CLBatteryVisualState)limitOnlyVisualStateForManager:"
                "(CLBatteryManager *)manager",
            )
        )
        for banned in ("amperage", "instantAmperage", "policyState"):
            self.assertNotIn(
                banned,
                body,
                f"仅限流视觉判据不得读 {banned}：仅限流模式下该字段已停止更新",
            )
        # scope=Off 的判断必须真的门控着返回关闭态
        branch = if_block(
            body,
            r"manager\.limitOnlyActiveScope\s*==\s*CLLimitOnlyScopeOff",
            "limitOnlyVisualStateForManager: 的关闭分支",
        )
        self.assertIn("CLBatteryVisualStateLimitOnlyOff", branch)
        self.assertIn("limitOnlyActiveLevel", body)

    def test_limit_only_level_mapping_is_complete(self):
        body = strip_comments(
            method_body(
                VC,
                "- (CLBatteryVisualState)limitOnlyVisualStateForManager:"
                "(CLBatteryManager *)manager",
            )
        )
        expected = {
            "nominal": "CLBatteryVisualStateLimitOnlyNominal",
            "light": "CLBatteryVisualStateLimitOnlyLight",
            "moderate": "CLBatteryVisualStateLimitOnlyModerate",
            "heavy": "CLBatteryVisualStateLimitOnlyHeavy",
        }
        for level, state in expected.items():
            branch = if_block(
                body,
                r'\[level isEqualToString:@"' + level + r'"\]',
                f"档位 {level} 的映射分支",
            )
            self.assertIn(state, branch, f"{level} 应映射到 {state}")

    def test_limit_only_icon_judgement_uses_charging_period(self):
        body = strip_comments(
            method_body(
                VC,
                "- (NSString *)limitOnlyIconNameForState:(CLBatteryVisualState)state "
                "manager:(CLBatteryManager *)manager",
            )
        )
        branch = if_block(
            body,
            r"\[manager limitOnlyChargingPeriodApplies\]",
            "limitOnlyIconNameForState:manager: 的插电充电分支",
        )
        self.assertIn('@"bolt.fill"', branch)
        # 未插电充电时按档位取图标
        for name, icon in LEVEL_ICONS.items():
            block = case_block(body, f"CLBatteryVisualState{name}")
            self.assertIn(
                f'return @"{icon}";',
                strip_comments(block),
                f"{name} 未插电充电时应返回 @\"{icon}\"",
            )

    def test_level_name_lookup_matches_card_copy(self):
        body = strip_comments(
            method_body(
                VC, "- (NSString *)limitOnlyLevelNameForManager:(CLBatteryManager *)manager"
            )
        )
        for level, name in LEVEL_NAMES.items():
            branch = if_block(
                body,
                r'\[level isEqualToString:@"' + level + r'"\]',
                f"档位名 {level} 的查表分支",
            )
            self.assertIn(f'CLL(@"{name}")', branch, f"{level} 的中文名应为 {name}")

    def test_status_text_uses_limit_only_copy(self):
        # applyBatteryManager:statusText: 必须在仅限流态换成限流专属文案。
        # 只测 limitOnlyStatusTextForManager: 自身不够——整个分支被删掉、或被改成
        # `if (cond) ;` 把语句提出块外时，旧断言全绿（实测变异漏过）。
        body = strip_comments(
            method_body(
                VC,
                "- (void)applyBatteryManager:(CLBatteryManager *)manager "
                "statusText:(NSString *)statusText",
            )
        )
        branch = if_block(
            body,
            r"manager\.operationMode\s*==\s*CLOperationModeLimitOnly",
            "applyBatteryManager:statusText: 的文案替换",
        )
        self.assertIn(
            "limitOnlyStatusTextForManager:",
            branch,
            "仅限流态必须走限流专属文案；分支被删或语句被挪出块外都会被抓到",
        )
        # 非仅限流分支必须仍走调用方传入的 statusText
        self.assertIn("statusText", body)

        copy = strip_comments(
            method_body(
                VC, "- (NSString *)limitOnlyStatusTextForManager:(CLBatteryManager *)manager"
            )
        )
        off = if_block(
            copy,
            r"manager\.limitOnlyActiveScope\s*==\s*CLLimitOnlyScopeOff",
            "limitOnlyStatusTextForManager: 的关闭分支",
        )
        self.assertIn("限流未开启", off)
        self.assertIn("limitOnlyLevelNameForManager:", copy)


class ColorMatrixTests(unittest.TestCase):
    """配色矩阵：仅限流五档互异、均非绿；既有八态不动。"""

    def setUp(self):
        self.body = method_body(
            VC,
            "- (void)applyVisualStateAnimated:(BOOL)animated "
            "forceAnimationRestart:(BOOL)forceAnimationRestart",
        )

    def test_each_limit_only_level_has_its_own_non_green_primary(self):
        primaries = {}
        for name, color in LEVEL_COLORS.items():
            block = case_block(self.body, f"CLBatteryVisualState{name}")
            found = primary_colors(block)
            self.assertEqual(
                found,
                [color],
                f"{name} 的 primaryColor 应为 {color}，实际解析到 {found}",
            )
            self.assertNotIn(
                "systemGreenColor",
                found,
                f"{name} 的 primaryColor 不得是 systemGreenColor",
            )
            primaries[name] = color
        # 五档 primaryColor 必须逐档互异：同一个色值被两档占用即失去区分度
        duplicates = {c for c in primaries.values() if list(primaries.values()).count(c) > 1}
        self.assertEqual(sorted(duplicates), [], f"以下主色被多个档位同时占用：{sorted(duplicates)}")

    def test_existing_eight_states_keep_their_colors(self):
        for state, (color, _icon, _anim) in EXISTING_STATES.items():
            if color is None:
                continue  # LowBattery 主色随电量分叉，单独断言
            block = case_block(self.body, f"CLBatteryVisualState{state}")
            found = primary_colors(block)
            self.assertEqual(
                found,
                [color],
                f"既有状态 {state} 的 primaryColor 应为 {color}，实际解析到 {found}",
            )

    def test_existing_eight_states_keep_their_icons(self):
        # 状态图标由 statusIconNameForVisualState: 提供，不在 applyVisualStateAnimated: 里
        body = strip_comments(
            method_body(
                VC, "- (NSString *)statusIconNameForVisualState:(CLBatteryVisualState)state"
            )
        )
        for state, (_color, icon, _anim) in EXISTING_STATES.items():
            if icon is None:
                continue  # IdleNormal / LowBattery 无状态图标，单独断言
            block = case_block(body, f"CLBatteryVisualState{state}")
            self.assertIn(
                f'return @"{icon}";',
                block,
                f"既有状态 {state} 的状态图标应为 @\"{icon}\"",
            )

    def test_existing_states_without_icon_stay_without_icon(self):
        body = strip_comments(
            method_body(
                VC, "- (NSString *)statusIconNameForVisualState:(CLBatteryVisualState)state"
            )
        )
        # 走 default 分支的状态一律返回 nil，不显示状态图标
        default = body[body.find("default:"):]
        self.assertIn("return nil;", default, "默认分支应返回 nil（不显示状态图标）")
        # 五个仅限流态不能被塞进这个 switch——它们的图标由 limitOnlyIconNameForState:manager: 出
        for name in LEVEL_ICONS:
            self.assertNotIn(
                f"CLBatteryVisualState{name}",
                body,
                f"{name} 不应出现在 statusIconNameForVisualState: 里",
            )

    def test_low_battery_threshold_and_split_colors(self):
        block = strip_comments(case_block(self.body, "CLBatteryVisualStateLowBattery"))
        # 低电量分叉判据是 self.percentage <= 10
        self.assertIn("self.percentage <= 10", block)
        branch = if_block(
            block, r"self\.percentage\s*<=\s*10", "LowBattery 的 ≤10% 分支"
        )
        self.assertIn("systemRedColor", primary_colors(branch))
        # >10% 走橙色：直接检查块内另一处 primaryColor 赋值
        self.assertIn("systemOrangeColor", block)

    def test_flow_opacity_comes_from_single_lookup(self):
        # 静态不透明度与动画启动参数必须同一个来源，否则两处数值会漂移
        self.assertIn("limitOnlyFlowOpacityForState:state]", self.body)

    def test_limit_only_static_opacities_match_matrix(self):
        for name, (_duration, opacity) in FLOW_PARAMS.items():
            block = case_block(self.body, f"CLBatteryVisualState{name}")
            self.assertNotIn(
                "flowOpacity =",
                strip_comments(block),
                f"{name} 不应在 case 里另写 flowOpacity，必须走查表",
            )


class AnimationMatrixTests(unittest.TestCase):
    """动画矩阵：关闭无循环、正常微光、轻/中/重流动且时长递减；既有八态动画参数不动。"""

    def test_needs_animation_matrix(self):
        body = method_body(
            VC, "- (BOOL)needsContinuousAnimationForState:(CLBatteryVisualState)state"
        )
        off = case_block(body, "CLBatteryVisualStateLimitOnlyOff")
        self.assertIn("return NO", off, "关闭档位不应播放循环动画")
        for name in ("LimitOnlyNominal", "LimitOnlyLight", "LimitOnlyModerate", "LimitOnlyHeavy"):
            block = case_block(body, f"CLBatteryVisualState{name}")
            self.assertIn("return YES", block, f"{name} 应需要连续动画")

    def test_has_animation_matrix(self):
        body = method_body(
            VC, "- (BOOL)hasContinuousAnimationForState:(CLBatteryVisualState)state"
        )
        nominal = case_block(body, "CLBatteryVisualStateLimitOnlyNominal")
        self.assertIn('@"cl.gloss"', nominal)
        for name in ("LimitOnlyLight", "LimitOnlyModerate", "LimitOnlyHeavy"):
            block = case_block(body, f"CLBatteryVisualState{name}")
            self.assertIn('@"cl.flow"', block, f"{name} 应判流动动画")

    def test_start_animation_matrix(self):
        body = method_body(VC, "- (void)startContinuousAnimationIfNeeded")
        nominal = case_block(body, "CLBatteryVisualStateLimitOnlyNominal")
        self.assertIn('@"cl.gloss"', nominal)
        bare = strip_comments(nominal)
        self.assertIn("@0.12", bare)
        self.assertIn("@0.28", bare)
        self.assertIn("duration = 2.6;", bare)
        for name in ("LimitOnlyLight", "LimitOnlyModerate", "LimitOnlyHeavy"):
            block = case_block(body, f"CLBatteryVisualState{name}")
            self.assertIn("startFlowAnimationWithDuration:", block)
        off = case_block(body, "CLBatteryVisualStateLimitOnlyOff")
        self.assertNotIn("startFlowAnimationWithDuration:", off)

    def test_flow_params_decrease_and_increase_with_level(self):
        body = method_body(
            VC, "- (CFTimeInterval)limitOnlyFlowDurationForState:(CLBatteryVisualState)state"
        )
        opacity_body = method_body(
            VC, "- (CGFloat)limitOnlyFlowOpacityForState:(CLBatteryVisualState)state"
        )
        durations = {}
        opacities = {}
        for name, (duration, opacity) in FLOW_PARAMS.items():
            dblock = case_block(body, f"CLBatteryVisualState{name}")
            dm = re.search(r"return\s+([0-9.]+)\s*;", dblock)
            self.assertIsNotNone(dm, f"{name} 缺少时长返回值")
            self.assertAlmostEqual(float(dm.group(1)), duration, places=6)
            durations[name] = float(dm.group(1))

            oblock = case_block(opacity_body, f"CLBatteryVisualState{name}")
            om = re.search(r"base\s*=\s*([0-9.]+)\s*;", oblock)
            self.assertIsNotNone(om, f"{name} 缺少 base 不透明度")
            self.assertAlmostEqual(float(om.group(1)), opacity, places=6)
            opacities[name] = float(om.group(1))

        self.assertGreater(durations["LimitOnlyLight"], durations["LimitOnlyModerate"])
        self.assertGreater(durations["LimitOnlyModerate"], durations["LimitOnlyHeavy"])
        self.assertLess(opacities["LimitOnlyLight"], opacities["LimitOnlyModerate"])
        self.assertLess(opacities["LimitOnlyModerate"], opacities["LimitOnlyHeavy"])
        # 减弱动态效果时不归零：归零就与"关闭档位"无法区分。
        # 断言整条表达式而不是裸 "0.4"——后者会被 `base = 0.40;` 里的子串糊弄过去。
        self.assertIn("shouldReduceMotion", opacity_body)
        self.assertIn("base * 0.4", opacity_body)

    def test_existing_states_animation_params_unchanged(self):
        body = method_body(VC, "- (void)startContinuousAnimationIfNeeded")
        charging = flow_params_of(body, "CLBatteryVisualStateCharging")
        self.assertEqual(charging, (1.25, 0.45), "Charging 的流动参数不应被改动")
        hold_recharge = flow_params_of(body, "CLBatteryVisualStateHoldRecharge")
        self.assertEqual(hold_recharge, (2.0, 0.28), "HoldRecharge 的流动参数不应被改动")
        temp = case_block(body, "CLBatteryVisualStateTempPaused")
        temp_bare = strip_comments(temp)
        self.assertIn('@"cl.temperature"', temp_bare)
        self.assertIn("duration = 1.45;", temp_bare)
        low = case_block(body, "CLBatteryVisualStateLowBattery")
        low_bare = strip_comments(low)
        self.assertIn('@"cl.lowBatteryPulse"', low_bare)
        self.assertIn("duration = 0.9;", low_bare)
        idle = case_block(body, "CLBatteryVisualStateIdleNormal")
        idle_bare = strip_comments(idle)
        self.assertIn('@"cl.gloss"', idle_bare)
        self.assertIn("duration = 2.6;", idle_bare)


class RefreshChainTests(unittest.TestCase):
    """刷新链路：仅限流模式下必须补发通知，且不得引入递归。"""

    def test_daemon_failure_branch_reposts_battery_notification(self):
        body = method_body(MANAGER, "- (void)refreshBatteryInfo")
        branch = if_block(
            body,
            r"self\.operationMode\s*==\s*CLOperationModeLimitOnly",
            "daemon 失败分支的仅限流处理",
        )
        self.assertIn("refreshDirectSessionState", branch)
        self.assertIn(
            "CLBatteryInfoDidUpdateNotification",
            branch,
            "补发通知必须在仅限流门控块内；挪到块外会被这里抓到",
        )

    def test_no_repost_inside_refresh_direct_session_state(self):
        # batteryInfoDidUpdate 在仅限流模式下会回调 refreshDirectSessionState；
        # 在它内部发电池事件通知会形成无限递归。
        body = method_body(MANAGER, "- (void)refreshDirectSessionState")
        self.assertNotIn(
            "CLBatteryInfoDidUpdateNotification",
            body,
            "不得在 refreshDirectSessionState 内补发电池事件通知（会成环）",
        )

    def test_mode_switch_reposts_immediately(self):
        body = method_body(
            MANAGER,
            "- (void)switchToMode:(CLOperationMode)mode "
            "completion:(void (^)(BOOL))completion",
        )
        condition = (
            r"mode\s*==\s*CLOperationModeLimitOnly\s*\|\|\s*"
            r"current\s*==\s*CLOperationModeLimitOnly"
        )
        branch = if_block(body, condition, "switchToMode: 的补发通知")
        self.assertIn("CLBatteryInfoDidUpdateNotification", branch)
        # 只覆盖涉限流的两个方向，不给其余切换多加通知
        self.assertIn("mode == CLOperationModeLimitOnly", body)
        self.assertIn("current == CLOperationModeLimitOnly", body)

    def test_level_apply_reposts(self):
        body = method_body(
            MANAGER,
            "- (void)applyLimitOnlyLevelsWithChargeMode:(NSString *)chargeMode "
            "idleMode:(NSString *)idleMode completion:(void (^)(BOOL success))completion",
        )
        branch = if_block(
            body,
            r"self\.operationMode\s*==\s*CLOperationModeLimitOnly",
            "档位改写后的补发通知",
        )
        self.assertIn("CLBatteryInfoDidUpdateNotification", branch)

    def test_settings_vc_refreshes_icon_on_appear_in_limit_only(self):
        body = method_body(VC, "- (void)viewWillAppear:(BOOL)animated")
        branch = if_block(
            body,
            r"\[\s*CLBatteryManager\s+shared\]\.operationMode\s*==\s*CLOperationModeLimitOnly",
            "viewWillAppear 的启动重算",
        )
        self.assertIn("batteryInfoDidUpdate", branch)


class CopyTests(unittest.TestCase):
    """文案：限流专属键必须中英成对，且不落进 lang.json。"""

    ENTRY_RE = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.S)
    REQUIRED = ["限流中 · %@", "限流未开启"]

    @staticmethod
    def _keys(path):
        import json
        from pathlib import Path

        text = Path(path).read_text(encoding="utf-8")
        return {m.group(1) for m in CopyTests.ENTRY_RE.finditer(text)}

    def test_limit_only_status_keys_exist_in_both_languages(self):
        from pathlib import Path

        app = Path(__file__).resolve().parents[2] / "ChargeLimiter"
        for lang in ("zh-Hans", "en"):
            keys = self._keys(app / f"{lang}.lproj" / "Localizable.strings")
            for key in self.REQUIRED:
                self.assertIn(key, keys, f"{lang}.lproj 缺少 {key}")

    def test_no_new_settings_copy_in_lang_json(self):
        import json
        from pathlib import Path

        lang = json.loads(
            (Path(__file__).resolve().parents[2] / "ChargeLimiter" / "lang.json").read_text(
                encoding="utf-8"
            )
        )
        for locale, table in lang.items():
            for banned in self.REQUIRED:
                self.assertNotIn(
                    banned,
                    table,
                    f"lang.json[{locale}] 不得新增设置面文案 {banned}",
                )


if __name__ == "__main__":
    unittest.main()
