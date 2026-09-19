from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
DAEMON_MM = ROOT / "ChargeLimiter" / "daemon.mm"
UTILS_MM = ROOT / "ChargeLimiter" / "utils.mm"
UTILS_H = ROOT / "ChargeLimiter" / "utils.h"
API_CLIENT_H = ROOT / "ChargeLimiter" / "UIKit" / "CLAPIClient.h"
API_CLIENT_M = ROOT / "ChargeLimiter" / "UIKit" / "CLAPIClient.m"
ADV_SETTINGS_M = ROOT / "ChargeLimiter" / "UIKit" / "Controllers" / "CLAdvancedSettingsViewController.m"
STRINGS_EN = ROOT / "ChargeLimiter" / "en.lproj" / "Localizable.strings"
STRINGS_ZH = ROOT / "ChargeLimiter" / "zh-Hans.lproj" / "Localizable.strings"


def function_body(source: str, signature: str) -> str:
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"unterminated function: {signature}")


class MCLPrefsContractTests(unittest.TestCase):
    """任务 2.1：层1 偏好读取层——白名单键、Missing/ReadFailed 语义、域扫描。"""

    @classmethod
    def setUpClass(cls):
        cls.utils_mm = UTILS_MM.read_text()
        cls.utils_h = UTILS_H.read_text()

    def test_whitelist_keys_exact_set(self):
        body = function_body(self.utils_mm, "NSArray<NSString*>* CLMCLPrefKeys(void) {")
        for key in ("MCLFeatureState", "currentState", "chargeLimitToken",
                    "mclLimitValue", "mclTargetSoC", "allowMCLOverride"):
            self.assertIn(f'@"{key}"', body)

    def test_candidate_domains_both_scanned(self):
        body = function_body(self.utils_mm, "static NSArray<NSString*>* CLMCLCandidateDomains(void) {")
        self.assertIn('@"com.apple.powerui.smartcharge"', body)
        self.assertIn('@"com.apple.powerui.smartcharging"', body)

    def test_read_prefs_distinguishes_missing_vs_read_failed(self):
        body = function_body(self.utils_mm, "BOOL CLMCLReadPrefs(NSMutableDictionary* outPrefs) {")
        self.assertIn("fileExistsAtPath", body)        # 域存在性判定
        self.assertIn("CLMCLPrefReadFailed", body)      # 读取异常标记（区分于缺失）
        self.assertIn("CLMCLPrefMissing", body)         # 缺失标记
        self.assertIn('@"unresolved"', body)            # 域未解析报告

    def test_read_agent_state_reuses_existing_xpc_channel(self):
        body = function_body(self.utils_mm, "BOOL CLMCLReadAgentState(int* obcStatus, BOOL* mclSupported, BOOL* mclEnabled) {")
        self.assertIn("isSmartChargeMCLSupported()", body)
        self.assertIn("getSmartChargeStatus()", body)
        self.assertIn("getSmartChargeMCLEnabled()", body)

    def test_declarations_in_header(self):
        self.assertIn("CLMCLPrefMissing = 0", self.utils_h)
        self.assertIn("CLMCLPrefFound = 1", self.utils_h)
        self.assertIn("CLMCLPrefReadFailed = 2", self.utils_h)
        self.assertIn("NSArray<NSString*>* CLMCLPrefKeys(void);", self.utils_h)
        self.assertIn("BOOL CLMCLReadPrefs(NSMutableDictionary* outPrefs);", self.utils_h)
        self.assertIn("BOOL CLMCLReadAgentState(int* obcStatus, BOOL* mclSupported, BOOL* mclEnabled);", self.utils_h)


class MCLLivePrefsChannelContractTests(unittest.TestCase):
    """任务 5.3：层1 活通道——cfprefsd 服务端缓冲直读，补磁盘直读盲区。

    真机轮 1 根因：poweruiagent 以 mobile 用户经 cfprefsd 写偏好，plist 可能长期
    不落盘甚至从不存在；「文件读不到」≠「偏好为空」≠「服务端没写」。活通道以
    mobile 用户运行 /usr/bin/defaults read 读 cfprefsd 真相，通道不可用时报告
    降级（unavailable + 原因），不崩溃。
    """

    @classmethod
    def setUpClass(cls):
        cls.utils_mm = UTILS_MM.read_text()
        cls.utils_h = UTILS_H.read_text()

    def test_live_declaration_in_header(self):
        self.assertIn("BOOL CLMCLReadPrefsLive(NSMutableDictionary* outLive);", self.utils_h)

    def test_live_channel_enumerates_pref_files_case_insensitive(self):
        body = function_body(self.utils_mm, "BOOL CLMCLReadPrefsLive(NSMutableDictionary* outLive) {")
        self.assertIn("/var/mobile/Library/Preferences/", body)
        self.assertIn('@"pref_files"', body)
        self.assertIn("NSCaseInsensitiveSearch", body)
        self.assertIn("powerui", body)
        self.assertIn("smartcharg", body)

    def test_live_channel_reports_channel_status(self):
        body = function_body(self.utils_mm, "BOOL CLMCLReadPrefsLive(NSMutableDictionary* outLive) {")
        self.assertIn('@"channel"', body)
        self.assertIn('@"ok"', body)
        self.assertIn('@"unavailable"', body)
        self.assertIn('@"defaults_missing"', body)   # /usr/bin/defaults 缺失原因
        self.assertIn('@"spawn_failed"', body)       # spawn 失败原因
        self.assertIn('@"unresolved"', body)         # 两候选域均未命中

    def test_live_channel_spawns_defaults_per_candidate_domain(self):
        body = function_body(self.utils_mm, "BOOL CLMCLReadPrefsLive(NSMutableDictionary* outLive) {")
        self.assertIn("/usr/bin/defaults", body)
        self.assertIn("CLMCLSpawnDefaultsRead(", body)
        self.assertIn('@"raw"', body)

    def test_spawn_helper_forks_as_mobile_user_with_timeout(self):
        body = function_body(self.utils_mm, "static int CLMCLSpawnDefaultsRead(NSString* domain, NSMutableData* outData) {")
        self.assertIn("fork()", body)
        self.assertIn('getpwnam("mobile")', body)
        self.assertIn("setuid(", body)
        self.assertIn("execl(", body)
        self.assertIn("poll(", body)
        self.assertIn("3000", body)      # 超时保护约 3s
        self.assertIn("SIGKILL", body)   # 超时回收子进程，不卡诊断

    def test_parse_helper_distinguishes_domain_missing_readfailed_found(self):
        body = function_body(self.utils_mm, "static NSInteger CLMCLParseDefaultsDomainOutput(NSString* text, NSMutableDictionary* values, NSMutableDictionary* states) {")
        self.assertIn("does not exist", body)        # 活通道域不存在 → Missing
        self.assertIn("CLMCLPrefMissing", body)
        self.assertIn("CLMCLPrefFound", body)
        self.assertIn("CLMCLPrefReadFailed", body)   # 有输出但解析失败
        self.assertIn("NSPropertyListSerialization", body)

    def test_raw_output_truncated_at_8k(self):
        body = function_body(self.utils_mm, "static NSString* CLMCLTruncateRawData(NSData* data) {")
        self.assertIn("8192", body)


class MCLLiveFirstVerdictContractTests(unittest.TestCase):
    """任务 5.3：诊断判定活通道优先——磁盘 Missing/ReadFailed 时用 live 值判定。

    pref_lost 仅在双通道（磁盘 + 活通道）都无法证实 MCLFeatureState=true 时给出；
    verdict 枚举不变，报告标注判定生效通道（effective_channel）。
    """

    @classmethod
    def setUpClass(cls):
        cls.daemon_mm = DAEMON_MM.read_text()

    def test_layer1_embeds_live_subdict_after_disk_read(self):
        body = function_body(self.daemon_mm, "static NSDictionary* collectMCLDiagnosticsWithLayer3(NSDictionary* layer3Override) {")
        disk = body.index("CLMCLReadPrefs(layer1)")
        live = body.index("CLMCLReadPrefsLive(live)")
        embed = body.index('layer1[@"live"]')
        self.assertLess(disk, live)      # 磁盘快照在前，活通道紧随其后补盲
        self.assertLess(live, embed)

    def test_verdict_call_uses_live_first_merged_view(self):
        body = function_body(self.daemon_mm, "static NSDictionary* collectMCLDiagnosticsWithLayer3(NSDictionary* layer3Override) {")
        self.assertIn("MCLLiveFirstLayer1(", body)
        self.assertIn("MCLVerdictFromDiagnostics(mclSupported, verdictLayer1", body)
        # 原始磁盘 layer1 不得直接作为判定输入
        self.assertNotIn("MCLVerdictFromDiagnostics(mclSupported, layer1", body)

    def test_effective_channel_annotated_in_report(self):
        body = function_body(self.daemon_mm, "static NSDictionary* collectMCLDiagnosticsWithLayer3(NSDictionary* layer3Override) {")
        self.assertIn('layer1[@"effective_channel"]', body)

    def test_merge_helper_disk_first_live_fallback(self):
        # 活通道优先 = 仅磁盘 Missing/ReadFailed 的键采用 live 值；磁盘可读时磁盘优先
        body = function_body(self.daemon_mm, "static NSDictionary* MCLLiveFirstLayer1(NSDictionary* layer1, NSString** effectiveChannel) {")
        disk_check = body.index("diskState == CLMCLPrefFound")
        live_check = body.index("liveState == CLMCLPrefFound")
        self.assertLess(disk_check, live_check)
        self.assertIn('@"disk"', body)
        self.assertIn('@"live"', body)
        self.assertIn('@"none"', body)   # 双通道均未证实

    def test_verdict_enums_unchanged(self):
        body = function_body(self.daemon_mm, "static NSString* MCLVerdictFromDiagnostics(BOOL mclSupported, NSDictionary* layer1, BOOL agentEnabled, NSDictionary* layer3) {")
        for verdict in ("healthy_enabled", "healthy_disabled", "disconnected", "pref_lost", "unsupported"):
            self.assertIn(f'@"{verdict}"', body)


class MCLRepairAttributionGuardContractTests(unittest.TestCase):
    """任务 5.3：修复归因守卫——活通道证实写入则不得归 gate1/gate2。

    真机轮 1：mcl_supported=true 已证 augury 门是开的，仅凭磁盘读不到（cfprefsd
    缓冲态不落盘）归因 gate1_augury_feature 自相矛盾。归因改为磁盘读或活通道任一
    证实 MCLFeatureState=true 即算写入；两通道都证伪才归 gate1/gate2。活通道证实
    已写但 after.layer2.mcl_enabled=false → still_disconnected + note。
    """

    @classmethod
    def setUpClass(cls):
        cls.daemon_mm = DAEMON_MM.read_text()

    def _inner_body(self):
        return function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepairInner(void) {")

    def test_feature_written_accepts_live_channel_proof(self):
        body = self._inner_body()
        disk = body.index("BOOL diskProven")
        live = body.index("BOOL liveProven")
        written = body.index("featureWritten = diskProven || liveProven")
        self.assertLess(disk, live)
        self.assertLess(live, written)
        self.assertIn('afterDiag[@"layer1"][@"live"]', body)

    def test_gate_attribution_only_when_both_channels_disprove(self):
        body = self._inner_body()
        live_proven = body.index("BOOL liveProven")
        gate_branch = body.index("if (!featureWritten)")
        gate1 = body.index('@"gate1_augury_feature"')
        # gate 归因必须位于双通道均证伪（!featureWritten）分支内，且在活通道证实逻辑之后
        self.assertLess(live_proven, gate_branch)
        self.assertLess(gate_branch, gate1)

    def test_live_proven_agent_not_flipped_maps_to_still_disconnected_with_note(self):
        body = self._inner_body()
        self.assertIn('[afterDiag[@"layer2"][@"mcl_enabled"]', body)
        note = body.index("mcl_feature_state_confirmed_by_live_channel")
        gate1 = body.index('@"gate1_augury_feature"')
        self.assertGreater(note, gate1)   # note 属于活通道证实路径，不属 gate 分支
        self.assertIn('@"note"', body)

    def test_advice_stays_reboot_and_retry(self):
        body = self._inner_body()
        self.assertIn('@"reboot_and_retry"', body)
        self.assertIn("MCLRollbackPrefs(", body)   # 回滚语义不变


class MCLForceEntryContractTests(unittest.TestCase):
    """任务 3.1：强制入口无读回短路、无条件下发；既有调用方语义不变。"""

    @classmethod
    def setUpClass(cls):
        cls.utils_mm = UTILS_MM.read_text()
        cls.utils_h = UTILS_H.read_text()

    def test_force_enable_has_no_readback_shortcircuit(self):
        body = function_body(self.utils_mm, "BOOL CLMCLForceEnable(void) {")
        self.assertIn("[client enableMCL:&err]", body)
        self.assertNotIn("getSmartChargeMCLEnabled() ==", body)

    def test_force_disable_has_no_readback_shortcircuit(self):
        body = function_body(self.utils_mm, "BOOL CLMCLForceDisable(void) {")
        self.assertIn("[client disableMCL:&err]", body)
        self.assertNotIn("getSmartChargeMCLEnabled() ==", body)

    def test_legacy_set_keeps_readback_shortcircuit(self):
        body = function_body(self.utils_mm, "BOOL setSmartChargeMCLEnabled(BOOL flag) {")
        self.assertIn("if (getSmartChargeMCLEnabled() == flag) {", body)  # v1.16.1 语义不变

    def test_both_force_entries_gated_by_capability_probe(self):
        for fn in ("BOOL CLMCLForceEnable(void) {", "BOOL CLMCLForceDisable(void) {"):
            body = function_body(self.utils_mm, fn)
            self.assertIn("isSmartChargeMCLSupported()", body, msg=fn)

    def test_declarations_in_header(self):
        self.assertIn("BOOL CLMCLForceEnable(void);", self.utils_h)
        self.assertIn("BOOL CLMCLForceDisable(void);", self.utils_h)


class MCLDiagnosticsContractTests(unittest.TestCase):
    """任务 2.2：诊断编排——字段集合、判定矩阵全分支、iOS 16 门控、读写分离。"""

    @classmethod
    def setUpClass(cls):
        cls.daemon_mm = DAEMON_MM.read_text()

    def test_get_bat_info_embeds_mcl_diagnostics(self):
        body = function_body(self.daemon_mm, 'else if ([api isEqualToString:@"get_bat_info"]) {')
        self.assertIn('data[@"MCLDiagnostics"] = collectMCLDiagnostics();', body)

    def test_get_mcl_diagnostics_readonly_api_exists(self):
        self.assertIn('"get_mcl_diagnostics"', self.daemon_mm)
        self.assertIn("collectMCLDiagnostics()", self.daemon_mm)

    def test_ios16_gate_returns_early_with_zero_collection(self):
        body = function_body(self.daemon_mm, "static NSDictionary* collectMCLDiagnosticsWithLayer3(NSDictionary* layer3Override) {")
        early = body.index("if (!mclSupported) {")
        head = body[early:early + 400]
        self.assertNotIn("CLMCLReadPrefs(", head)       # 早退分支内不得做层1/层2 收集
        self.assertNotIn("CLMCLReadAgentState(", head)
        self.assertIn('@"unsupported"', head)

    def test_verdict_matrix_all_five_rows(self):
        body = function_body(self.daemon_mm, "static NSString* MCLVerdictFromDiagnostics(BOOL mclSupported, NSDictionary* layer1, BOOL agentEnabled, NSDictionary* layer3) {")
        for verdict in ("healthy_enabled", "healthy_disabled", "disconnected", "pref_lost", "unsupported"):
            self.assertIn(f'@"{verdict}"', body)
        self.assertIn("registry_diff", body)

    def test_layer3_diff_targets_limit_or_override_keys(self):
        body = function_body(self.daemon_mm, "static NSDictionary* MCLDiffRegistryProps(NSDictionary* before, NSDictionary* after) {")
        self.assertIn('containsString:@"limit"', body)
        self.assertIn('containsString:@"override"', body)
        self.assertIn('@"limit_related"', body)

    def test_standalone_layer3_degrades_to_indirect_without_candidates(self):
        body = function_body(self.daemon_mm, "static NSDictionary* MCLLayer3EvidenceStandalone(void) {")
        self.assertIn('@"indirect"', body)
        self.assertIn("MCLRegistryEvidenceCandidateKeys()", body)


class MCLRepairContractTests(unittest.TestCase):
    """任务 3.2：修复编排——调用序列、busy 守卫、健康无副作用、iOS 16 零写入、回滚。

    相对 brief 测试代码的两处扩展（跨任务协调上下文要求）：
    1. 失败分支含 gate1/gate2 四分类：re-notes F2 新发现——enableMCL 在写偏好前有
       两个静默 bail 门（gate1 augury feature；gate2 DeviceSupports80ChargeLimit
       为假且非内部构建），报告须能区分（gate_evidence 携带 MobileGestalt 原始值）。
    2. mcl_repair_* 时间线事件经 appendMCLRepairCoordinationEvent 直写 policy 事件
       时间线：appendSmartChargeCoordinationEvent 在 from==to 时丢弃事件（daemon.mm
       转移过滤），而 MCL 修复不改充电状态，brief 参考代码的调用会被静默吞掉。
    """

    @classmethod
    def setUpClass(cls):
        cls.daemon_mm = DAEMON_MM.read_text()

    def test_repair_dispatched_via_post_api(self):
        self.assertIn('"repair_mcl_limit"', self.daemon_mm)
        self.assertIn("performMCLLimitRepair()", self.daemon_mm)

    def test_sequence_snapshot_then_normalize_then_force_then_recheck(self):
        body = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepairInner(void) {")
        snap = body.index("CLMCLReadPrefs(beforePrefs)")
        normalize = body.index("MCLNormalizePrefsForRepair(beforePrefs)")
        force = body.index("CLMCLForceEnable()")
        recheck = body.index("collectMCLDiagnosticsWithLayer3(")
        self.assertLess(snap, normalize)
        self.assertLess(normalize, force)
        self.assertLess(force, recheck)

    def test_healthy_disabled_keeps_semantics_no_write_no_force(self):
        # 无副作用约束（最终审查修复波复核）：healthy_disabled 是用户显式选项（OBC 关着
        # 没坏）——kept 提前返回必须出现在任何偏好写入（normalize）与 force enable 之前，
        # 该路径零写入零 force。
        body = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepairInner(void) {")
        disabled = body.index('isEqualToString:@"healthy_disabled"]')
        kept = body.index('@"kept"')
        normalize = body.index("MCLNormalizePrefsForRepair(beforePrefs)")
        force = body.index("CLMCLForceEnable()")
        self.assertLess(disabled, kept)
        self.assertLess(kept, normalize)
        self.assertLess(kept, force)  # healthy_disabled kept 路径不触发 force/写入
        self.assertIn('@"kept"', body)

    def test_healthy_enabled_kept_gated_on_execution_layer_evidence(self):
        # 最终审查 Important：healthy_enabled 的 kept 提前返回必须以执行层在场证据为前提
        # （evidence_grade == registry_diff 且 present == YES）。v1 层3 仅 indirect
        # （MCLRegistryEvidenceCandidateKeys() 为空、注册表稳定键无静态候选），受损设备
        # （偏好 MCLFeatureState=true + 代理读回 YES + 执行层断）会被判定矩阵归为
        # healthy_enabled（行 2 需 registry_diff 证据，当前不可达）——若读回短路 kept，
        # 修复按钮即成空操作，违背 delta spec「强制修复 80% 限制」第 1 条（不信任读回
        # 短路，即使读回等于目标值仍 MUST 执行修复序列）。证据核对必须出现在
        # healthy_enabled 比较与 kept 返回之间。
        body = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepairInner(void) {")
        gate = body.index('isEqualToString:@"healthy_enabled"]')
        kept = body.index('@"kept"')
        gate_region = body[gate:kept]
        self.assertIn("evidence_grade", gate_region)
        self.assertIn('@"registry_diff"', gate_region)
        self.assertIn('@"present"', gate_region)

    def test_healthy_enabled_registry_diff_present_is_kept(self):
        # healthy_enabled + registry_diff + present=YES（未来候选键填充后、执行层已被证实
        # 在场：判定矩阵行 2 已排除 disconnected）→ 同样 kept，不做幂等重申的额外写入。
        # 实现层面与 indirect 分流共用同一证据核对（见上一用例），本用例锁 kept 返回仍在
        # 证据核对之后、修复序列（normalize/force）之前可达。
        body = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepairInner(void) {")
        gate = body.index('isEqualToString:@"healthy_enabled"]')
        kept = body.index('@"kept"')
        normalize = body.index("MCLNormalizePrefsForRepair(beforePrefs)")
        self.assertLess(gate, kept)
        self.assertLess(kept, normalize)  # 证据证实的 healthy_enabled 在修复序列之前 kept

    def test_healthy_enabled_indirect_still_reaches_repair_sequence(self):
        # healthy_enabled + indirect（未证实）不得被 kept 短路吞掉：kept 仅是证据条件分支，
        # 其后修复序列（规范化 → CLMCLForceEnable → 复核）仍须可达；该路径返回沿用
        # action=repaired + verdict_before=healthy_enabled（无需新枚举）——真健康设备为
        # 幂等重申（服务端重写 MCLFeatureState=true + 重设 limit 80，用户选项语义不变），
        # 假健康设备才是真正修复。
        body = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepairInner(void) {")
        gate = body.index('isEqualToString:@"healthy_enabled"]')
        kept = body.index('@"kept"')
        normalize = body.index("MCLNormalizePrefsForRepair(beforePrefs)")
        force = body.index("CLMCLForceEnable()")
        recheck = body.index("collectMCLDiagnosticsWithLayer3(")
        self.assertLess(gate, kept)
        self.assertLess(kept, normalize)
        self.assertLess(normalize, force)
        self.assertLess(force, recheck)
        repaired = body.index('@"repaired"')
        self.assertLess(force, repaired)  # 修复序列成功路径返回 action=repaired
        self.assertIn('@"verdict_before"', body)

    def test_busy_guards(self):
        wrapper = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepair(void) {")
        self.assertIn("g_mclRepairRunning", wrapper)
        self.assertIn("MCLRepairLock()", wrapper)
        inner = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepairInner(void) {")
        self.assertIn("g_tempSmartChargeDisabledByCL", inner)  # 协调会话活跃拒绝
        self.assertIn('@"coordination_session_active"', inner)

    def test_ios16_zero_write_gate_in_wrapper(self):
        wrapper = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepair(void) {")
        gate = wrapper.index("@available(iOS 17.0, *)")
        lock = wrapper.index("MCLRepairLock()")
        self.assertLess(gate, lock)  # 旧系统在加锁/任何写入之前退出
        self.assertIn('@"unsupported"', wrapper)

    def test_failure_rolls_back_snapshot_and_reports_branch(self):
        body = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepairInner(void) {")
        self.assertIn("MCLRollbackPrefs(", body)
        for branch in ("call_error", "gate1_augury_feature", "gate2_device_gate",
                       "qmax_neutralized", "token_zero", "still_disconnected"):
            self.assertIn(f'@"{branch}"', body)
        self.assertIn("DeviceSupports80ChargeLimit", body)   # gate2 MobileGestalt 证据探测
        self.assertIn('@"gate_evidence"', body)              # gate1/gate2 可区分的原始证据
        self.assertIn('@"reboot_and_retry"', body)
        self.assertIn('@"rollback"', body)

    def test_whitelist_only_normalization(self):
        body = function_body(self.daemon_mm, "static NSDictionary* MCLNormalizePrefsForRepair(NSMutableDictionary* layer1) {")
        for key in ("MCLFeatureState", "mclLimitValue", "mclTargetSoC"):
            self.assertIn(f'@"{key}"', body)
        self.assertNotIn('@"currentState"', body)          # 服务端自有键不写
        self.assertNotIn('@"chargeLimitToken"', body)      # token 生命周期归服务端（F5）

    def test_normalize_skips_when_plist_unreadable_at_write(self):
        # 修复轮 1（审查 Important）：CLMCLReadPrefs 快照与 normalize 重读之间存在 TOCTOU——
        # states 检查只保证快照时刻可解析，重读失败（文件被删/损坏）时若以空字典继续写，
        # 会整体覆盖 plist、丢掉全部非白名单键。重读 nil 必须 skip 零写入。
        body = function_body(self.daemon_mm, "static NSDictionary* MCLNormalizePrefsForRepair(NSMutableDictionary* layer1) {")
        reread = body.index("dictionaryWithContentsOfFile:path")
        nil_skip = body.index('@"plist_unreadable_at_write"')
        write = body.index("writeToFile:path")
        self.assertLess(reread, nil_skip)    # 重读 nil 分支即返回 skip
        self.assertLess(nil_skip, write)     # skip 在任何 writeToFile 之前
        self.assertNotIn("dict = [NSMutableDictionary dictionary]", body)  # 空字典兜底已移除

    def test_coordination_timeline_events(self):
        body = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepairInner(void) {")
        self.assertIn('@"mcl_repair_started"', body)
        self.assertIn('@"mcl_repair_finished"', body)
        self.assertIn("appendMCLRepairCoordinationEvent", body)
        helper = function_body(self.daemon_mm, "static void appendMCLRepairCoordinationEvent(NSString* reason, NSDictionary* extras) {")
        self.assertIn("appendPolicyEventHistory", helper)   # 与协调事件同一 policy 事件时间线

    def test_no_daemon_restart_in_repair(self):
        body = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepairInner(void) {")
        self.assertNotIn("killall", body)
        self.assertNotIn("launchctl", body)   # Design Doc：不重启 poweruiagent


class MCLDiagnosticsUIContractTests(unittest.TestCase):
    """任务 4.1：MCL 诊断区块、复制导出、双语资源同步、API client。"""

    @classmethod
    def setUpClass(cls):
        cls.adv_settings_m = ADV_SETTINGS_M.read_text()
        cls.api_client_h = API_CLIENT_H.read_text()
        cls.api_client_m = API_CLIENT_M.read_text()
        cls.strings_en = STRINGS_EN.read_text()
        cls.strings_zh = STRINGS_ZH.read_text()

    def test_api_client_has_diagnostics_method(self):
        self.assertIn("getMCLDiagnosticsWithCompletion:", self.api_client_h)
        self.assertIn('"api": @"get_mcl_diagnostics"', self.api_client_m)
        self.assertIn('@"get_mcl_diagnostics"', self.api_client_m)  # mock 分支

    def test_setup_content_has_mcl_card(self):
        body = function_body(self.adv_settings_m, "- (void)setupContent {")
        self.assertIn('addSectionHeader:CLL(@"MCL 80% 限制诊断")', body)
        for label_key in ("mcl_verdict", "mcl_domain", "mcl_l1_feature", "mcl_l1_token",
                          "mcl_l1_limit", "mcl_l2", "mcl_l3"):
            self.assertIn(f'@"{label_key}"', body)
        self.assertIn("copyMCLDiagnosticsTapped:", body)

    def test_copy_exports_full_report_json(self):
        body = function_body(self.adv_settings_m, "- (void)copyMCLDiagnosticsTapped:(UITapGestureRecognizer *)tap {")
        self.assertIn("NSJSONSerialization", body)
        self.assertIn("UIPasteboard generalPasteboard].string", body)
        self.assertIn("lastMCLDiagnostics", body)

    def test_viewWillAppear_refreshes_mcl(self):
        body = function_body(self.adv_settings_m, "- (void)viewWillAppear:(BOOL)animated {")
        self.assertIn("refreshMCLDiagnostics", body)

    def test_verdict_mapping_covers_all_states(self):
        body = function_body(self.adv_settings_m, "- (NSString *)mclVerdictText:(NSString *)verdict {")
        for verdict in ("healthy_enabled", "healthy_disabled", "disconnected", "pref_lost", "unsupported"):
            self.assertIn(f'@"{verdict}"', body)

    def test_layer1_state_labels_distinguish_missing_vs_failed(self):
        body = function_body(self.adv_settings_m, "- (NSString *)mclLayer1KeyText:(NSDictionary *)diag key:(NSString *)key {")
        self.assertIn("键不存在", body)
        self.assertIn("读取失败", body)

    def test_bilingual_strings_synced(self):
        for key in ("MCL 80% 限制诊断", "一致性判定", "偏好域", "偏好层 MCLFeatureState",
                    "偏好层 chargeLimitToken", "偏好层限制值/目标", "代理内存层读回",
                    "执行层证据", "复制 MCL 诊断报告", "键不存在", "读取失败",
                    "一致启用（健康）", "一致停用（健康）", "脱节", "偏好丢失", "不支持",
                    "MCL 诊断报告已复制到剪贴板。", "请等待 MCL 诊断刷新完成。"):
            self.assertIn(f'"{key}"', self.strings_en)
            self.assertIn(f'"{key}"', self.strings_zh)


class MCLRepairUIContractTests(unittest.TestCase):
    """任务 4.2：强制修复按钮——二次确认、调用、分层结果反馈、按钮互斥。"""

    @classmethod
    def setUpClass(cls):
        cls.adv_settings_m = ADV_SETTINGS_M.read_text()
        cls.api_client_h = API_CLIENT_H.read_text()
        cls.api_client_m = API_CLIENT_M.read_text()
        cls.strings_en = STRINGS_EN.read_text()
        cls.strings_zh = STRINGS_ZH.read_text()

    def test_api_client_has_repair_method(self):
        self.assertIn("repairMCLLimitWithCompletion:", self.api_client_h)
        self.assertIn('"api": @"repair_mcl_limit"', self.api_client_m)
        self.assertIn('@"repair_mcl_limit"', self.api_client_m)  # mock 分支

    def test_repair_button_in_mcl_card(self):
        body = function_body(self.adv_settings_m, "- (void)setupContent {")
        self.assertIn('title:CLL(@"强制修复 80% 限制")', body)
        self.assertIn("repairMCLLimitTapped:", body)
        self.assertIn("tag:931", body)

    def test_tap_asks_confirmation_then_runs(self):
        body = function_body(self.adv_settings_m, "- (void)repairMCLLimitTapped:(UITapGestureRecognizer *)tap {")
        self.assertIn("UIAlertController", body)
        self.assertIn("runMCLRepair", body)

    def test_run_calls_api_and_renders(self):
        body = function_body(self.adv_settings_m, "- (void)runMCLRepair {")
        self.assertIn("repairMCLLimitWithCompletion", body)
        self.assertIn("mclRepairResultMessage", body)
        self.assertIn("refreshMCLDiagnostics", body)

    def test_result_message_maps_branches_and_busy(self):
        body = function_body(self.adv_settings_m, "- (NSString *)mclRepairResultMessage:(NSDictionary *)result {")
        self.assertIn('result[@"unsupported"]', body)
        self.assertIn('result[@"busy"]', body)
        self.assertIn('result[@"failure_branch"]', body)
        self.assertIn('@"reboot_and_retry"', body)
        self.assertIn('@"kept"', body)

    def test_repair_button_disables_while_running(self):
        body = function_body(self.adv_settings_m, "- (void)setMCLRepairButtonEnabled:(BOOL)enabled {")
        self.assertIn("931", body)
        self.assertIn("userInteractionEnabled", body)

    def test_bilingual_strings_synced(self):
        for key in ("强制修复 80% 限制", "执行修复", "修复被拒绝：有协调会话正在进行，请稍后再试。",
                    "设备不支持：需要 iOS 17 及以上。", "设备健康：已保持当前充电优化选项，未做任何修改。",
                    "修复完成：80% 限制已重新下发，请插电充电验证。", "修复失败。失败分支：",
                    "建议：重启设备后重试。"):
            self.assertIn(f'"{key}"', self.strings_en)
            self.assertIn(f'"{key}"', self.strings_zh)


class MCLRepairFeedbackEvidenceContractTests(unittest.TestCase):
    """任务 5.3：App 修复反馈回灌——失败分支附关键证据两行 + 复制导出追加 last_repair。

    真机轮 1 需要直接判读「服务端写没写（force_enable_ok）/ 代理内存翻没翻
    （after.layer2.mcl_enabled）」；复制导出在 MCL 诊断 JSON 后附最近一次修复
    完整响应（键名 last_repair），供无直连设备手动回传。
    """

    @classmethod
    def setUpClass(cls):
        cls.adv_settings_m = ADV_SETTINGS_M.read_text()

    def test_result_message_failure_branch_appends_evidence_lines(self):
        body = function_body(self.adv_settings_m, "- (NSString *)mclRepairResultMessage:(NSDictionary *)result {")
        branch = body.index('result[@"failure_branch"]')
        force_ok = body.index("force_enable_ok")
        mcl_enabled = body.index("after.layer2.mcl_enabled")
        self.assertLess(branch, force_ok)     # 证据行属失败分支，非全局追加
        self.assertLess(branch, mcl_enabled)
        self.assertIn('result[@"force_enable_ok"]', body)
        self.assertIn('result[@"after"][@"layer2"][@"mcl_enabled"]', body)

    def test_run_stores_mcl_repair_result(self):
        body = function_body(self.adv_settings_m, "- (void)runMCLRepair {")
        self.assertIn("lastMCLRepairResult", body)

    def test_copy_export_appends_last_repair_json(self):
        body = function_body(self.adv_settings_m, "- (void)copyMCLDiagnosticsTapped:(UITapGestureRecognizer *)tap {")
        self.assertIn('@"last_repair"', body)
        self.assertIn("lastMCLRepairResult", body)
        self.assertIn("lastMCLDiagnostics", body)   # 诊断 JSON 仍是导出主体
        self.assertIn("NSJSONSerialization", body)
