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
        self.assertIn("BOOL CLMCLReadPrefsLive(NSMutableDictionary* outLive, BOOL forceRefresh);", self.utils_h)

    def test_live_channel_enumerates_pref_files_case_insensitive(self):
        body = function_body(self.utils_mm, "BOOL CLMCLReadPrefsLive(NSMutableDictionary* outLive, BOOL forceRefresh) {")
        self.assertIn("/var/mobile/Library/Preferences/", body)
        self.assertIn('@"pref_files"', body)
        self.assertIn("NSCaseInsensitiveSearch", body)
        self.assertIn("powerui", body)
        self.assertIn("smartcharg", body)

    def test_live_channel_reports_channel_status(self):
        body = function_body(self.utils_mm, "BOOL CLMCLReadPrefsLive(NSMutableDictionary* outLive, BOOL forceRefresh) {")
        self.assertIn('@"channel"', body)
        self.assertIn('@"ok"', body)
        self.assertIn('@"unavailable"', body)
        self.assertIn('@"defaults_missing"', body)   # /usr/bin/defaults 缺失原因
        self.assertIn('@"spawn_failed"', body)       # spawn 失败原因
        self.assertIn('@"unresolved"', body)         # 两候选域均未命中

    def test_live_channel_spawns_defaults_per_candidate_domain(self):
        body = function_body(self.utils_mm, "BOOL CLMCLReadPrefsLive(NSMutableDictionary* outLive, BOOL forceRefresh) {")
        self.assertIn("/usr/bin/defaults", body)
        self.assertIn("CLMCLSpawnDefaultsRead(", body)
        self.assertIn('@"raw"', body)

    def test_spawn_helper_forks_as_mobile_user_with_timeout(self):
        body = function_body(self.utils_mm, "static int CLMCLSpawnDefaultsRead(NSString* defaultsPath, NSString* domain, NSMutableData* outData) {")
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
        body = function_body(self.daemon_mm, "static NSDictionary* collectMCLDiagnosticsWithLayer3(NSDictionary* layer3Override, BOOL forceRefresh) {")
        disk = body.index("CLMCLReadPrefs(layer1)")
        live = body.index("CLMCLReadPrefsLive(live, forceRefresh)")
        embed = body.index('layer1[@"live"]')
        self.assertLess(disk, live)      # 磁盘快照在前，活通道紧随其后补盲
        self.assertLess(live, embed)

    def test_verdict_call_uses_live_first_merged_view(self):
        body = function_body(self.daemon_mm, "static NSDictionary* collectMCLDiagnosticsWithLayer3(NSDictionary* layer3Override, BOOL forceRefresh) {")
        self.assertIn("MCLLiveFirstLayer1(", body)
        self.assertIn("MCLVerdictFromDiagnostics(mclSupported, verdictLayer1", body)
        # 原始磁盘 layer1 不得直接作为判定输入
        self.assertNotIn("MCLVerdictFromDiagnostics(mclSupported, layer1", body)

    def test_effective_channel_annotated_in_report(self):
        body = function_body(self.daemon_mm, "static NSDictionary* collectMCLDiagnosticsWithLayer3(NSDictionary* layer3Override, BOOL forceRefresh) {")
        self.assertIn('layer1[@"effective_channel"]', body)

    def test_merge_helper_disk_first_live_fallback(self):
        # 磁盘优先为主：仅磁盘 Missing/ReadFailed 的键采用 live 值；MCLFeatureState 的
        # 「磁盘 false/live true」值冲突例外（live 优先）见 MCLFeatureStateConflictRuleContractTests
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
        body = function_body(self.daemon_mm, "static NSDictionary* collectMCLDiagnosticsWithLayer3(NSDictionary* layer3Override, BOOL forceRefresh) {")
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


class MCLLiveSpawnHardeningContractTests(unittest.TestCase):
    """任务 5.3 修复轮 2（审查发现 3/4/5）：活通道子进程加固。

    1. setuid/setgid 返回值检查：失败 _exit(126)——防止 defaults 以 root 身份读
       root 域 → 活通道静默全 Missing 复辟 gate1 误归因。
    2. waitpid 退出码降级：子进程 _exit(127)（exec 失败）→ 该域通道降级
       unavailable（reason exec_failed），不得解析为「域不存在」。
    3. 子进程 fd 收口：execl 前 close 从 STDERR+1 到 getdtablesize()——防 mobile
       用户子进程持有 root daemon 的 HTTP/XPC/日志 fd。
    """

    @classmethod
    def setUpClass(cls):
        cls.utils_mm = UTILS_MM.read_text()
        cls.utils_h = UTILS_H.read_text()

    def _spawn_body(self):
        return function_body(self.utils_mm, "static int CLMCLSpawnDefaultsRead(NSString* defaultsPath, NSString* domain, NSMutableData* outData) {")

    def _live_body(self):
        return function_body(self.utils_mm, "BOOL CLMCLReadPrefsLive(NSMutableDictionary* outLive, BOOL forceRefresh) {")

    def test_setgid_setuid_checked_and_fail_exit_126(self):
        body = self._spawn_body()
        self.assertIn("if (setgid(pw->pw_gid) != 0) _exit(126);", body)
        self.assertIn("if (setuid(pw->pw_uid) != 0) _exit(126);", body)
        self.assertLess(body.index("setgid(pw->pw_gid)"), body.index("setuid(pw->pw_uid)"))  # 先降组再降用户

    def test_waitpid_exit_code_downgrade_to_exec_failed(self):
        # 仅认子进程 _exit 哨兵码：127=exec 失败 → -3、126=提权失败 → -4；
        # defaults 自身退出码（域不存在走输出解析）与超时 SIGKILL（WIFSIGNALED）不受影响
        body = self._spawn_body()
        waitpid = body.index("waitpid(pid, &status, 0)")
        self.assertIn("WIFEXITED(status)", body)
        self.assertIn("WEXITSTATUS(status)", body)
        exited = body.index("WIFEXITED(status)")
        self.assertLess(waitpid, exited)   # 降级判定在 waitpid 之后
        self.assertIn("rc = -3", body)     # exec 失败（_exit(127)）
        self.assertIn("rc = -4", body)     # setgid/setuid 失败（_exit(126)）

    def test_live_channel_reports_exec_and_privilege_failure_reasons(self):
        # exec/提权失败均降级通道不可用，不得落进「域不存在/全 Missing」解析
        body = self._live_body()
        self.assertIn('@"exec_failed"', body)
        self.assertIn('@"setuid_failed"', body)
        self.assertEqual(body.count('outLive[@"channel"] = @"unavailable";'), 4)  # 缺工具/spawn/exec/提权四类
        self.assertIn("rc == -3", body)
        self.assertIn("rc == -4", body)

    def test_fd_sweep_closes_inherited_fds_before_execl(self):
        # execl 前 close STDERR+1 到 getdtablesize()：防 mobile 用户子进程持有 root daemon fd
        body = self._spawn_body()
        child = body.index("pid == 0")
        sweep = body.index("STDERR_FILENO + 1")
        setuid = body.index("setuid(pw->pw_uid)")
        execl = body.index("execl(")
        self.assertLess(child, sweep)      # 收口在子进程分支内
        self.assertLess(sweep, setuid)     # 收口在提权之前
        self.assertLess(sweep, execl)      # 收口在 execl 之前
        self.assertIn("getdtablesize()", body)


class MCLLiveChannelCacheContractTests(unittest.TestCase):
    """任务 5.3 修复轮 2（审查发现 1）：活通道 15s TTL 缓存 + force-refresh 直通。

    get_bat_info 1Hz 轮询每次收集 fork 两个 defaults 子进程（正常 +100~300ms/次，
    cfprefsd 异常时最坏 6s 且请求堆积）。按域缓存 raw+解析结果，TTL 15s 内复用；
    forceRefresh=YES 绕过缓存查找强制活读（修复复核专用），但仍回填缓存。
    """

    @classmethod
    def setUpClass(cls):
        cls.utils_mm = UTILS_MM.read_text()
        cls.utils_h = UTILS_H.read_text()

    def _live_body(self):
        return function_body(self.utils_mm, "BOOL CLMCLReadPrefsLive(NSMutableDictionary* outLive, BOOL forceRefresh) {")

    def test_ttl_constant_declared_with_15s(self):
        self.assertIn("kMCLLiveCacheTTLSeconds = 15", self.utils_mm)

    def test_cache_lookup_helper_has_ttl_expiry(self):
        body = function_body(self.utils_mm, "static NSDictionary* CLMCLLiveCacheEntry(NSString* domain) {")
        self.assertIn("kMCLLiveCacheTTLSeconds", body)   # 过期判定用 TTL 常量
        self.assertIn("timestamp", body)

    def test_cache_store_helper_exists(self):
        function_body(self.utils_mm, "static void CLMCLLiveCacheStore(NSString* domain, NSData* raw, int rc, NSInteger found, NSDictionary* values, NSDictionary* states) {")

    def test_live_read_takes_force_refresh_param(self):
        self.assertIn("BOOL CLMCLReadPrefsLive(NSMutableDictionary* outLive, BOOL forceRefresh);", self.utils_h)
        self.assertIn("forceRefresh", self._live_body())

    def test_cache_hit_gates_spawn_and_force_bypasses_lookup(self):
        body = self._live_body()
        bypass = body.index("forceRefresh ? nil : CLMCLLiveCacheEntry(domain)")
        spawn = body.index("CLMCLSpawnDefaultsRead(defaultsBin, domain, outData)")
        self.assertLess(bypass, spawn)   # 缓存查找在 spawn 之前门控
        self.assertIn("CLMCLLiveCacheStore(", body)   # fresh 分支统一回填

    def test_cache_hit_reuses_raw_and_parsed_result(self):
        body = self._live_body()
        cached = body.index("CLMCLLiveCacheEntry(domain)")
        reuse = body.index("cached[@\"raw\"]")
        values = body.index("cached[@\"values\"]")
        self.assertLess(cached, reuse)
        self.assertLess(cached, values)  # 命中路径复用 raw + 解析结果，不 fork


class MCLLiveCacheBypassContractTests(unittest.TestCase):
    """任务 5.3 修复轮 2（审查发现 1）：收集函数 force-refresh 参数与修复复核直通。

    关键约束：修复复核 ⑤ 必须绕过活通道缓存强制刷新（否则看不到 enableMCL 刚写入的
    live 值，归因守卫失效）；get_bat_info/get_mcl_diagnostics 常规路径与修复前快照、
    kept 路径 after 快照走缓存包装（collectMCLDiagnostics → force=NO）。
    """

    @classmethod
    def setUpClass(cls):
        cls.daemon_mm = DAEMON_MM.read_text()

    def _inner_body(self):
        return function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepairInner(void) {")

    def test_collect_takes_force_refresh_and_propagates_to_live(self):
        body = function_body(self.daemon_mm, "static NSDictionary* collectMCLDiagnosticsWithLayer3(NSDictionary* layer3Override, BOOL forceRefresh) {")
        self.assertIn("CLMCLReadPrefsLive(live, forceRefresh)", body)

    def test_cached_wrapper_passes_no_force(self):
        body = function_body(self.daemon_mm, "static NSDictionary* collectMCLDiagnostics(void) {")
        self.assertIn("collectMCLDiagnosticsWithLayer3(nil, NO)", body)

    def test_repair_recheck_bypasses_cache_after_force_enable(self):
        body = self._inner_body()
        force = body.index("CLMCLForceEnable()")
        recheck = body.index("collectMCLDiagnosticsWithLayer3(layer3Override, YES)")
        self.assertLess(force, recheck)  # 复核在 force enable 之后且强制刷新

    def test_recheck_after_diag_is_the_forced_collection(self):
        # 归因守卫消费的 afterDiag 必须来自强制刷新收集
        body = self._inner_body()
        self.assertIn("NSDictionary* afterDiag = collectMCLDiagnosticsWithLayer3(layer3Override, YES);", body)

    def test_before_snapshot_and_kept_after_use_cached_wrapper(self):
        # 修复前快照与 kept 提前返回的 after 快照走常规缓存路径（无写入，缓存语义安全）
        body = self._inner_body()
        self.assertIn("NSDictionary* beforeDiag = collectMCLDiagnostics();", body)
        self.assertIn("NSDictionary* afterDiag = collectMCLDiagnostics();", body)  # kept 路径


class MCLFeatureStateConflictRuleContractTests(unittest.TestCase):
    """任务 5.3 修复轮 2（审查发现 2）：MCLFeatureState 冲突 live 优先。

    磁盘 plist 是 cfprefsd 异步落盘副本，新鲜度恒 ≤ cfprefsd：双通道同时 Found 且
    磁盘=false / live=true 的组合只能是服务端刚写、磁盘滞后——仅 MCLFeatureState
    一键 live 优先，其余五键维持磁盘优先；冲突时 effective_channel 标
    conflict_live_wins。健康设备（disk=false/live=false）无冲突，零副作用。
    """

    @classmethod
    def setUpClass(cls):
        cls.daemon_mm = DAEMON_MM.read_text()

    def _merge_body(self):
        return function_body(self.daemon_mm, "static NSDictionary* MCLLiveFirstLayer1(NSDictionary* layer1, NSString** effectiveChannel) {")

    def test_conflict_rule_scoped_to_feature_state_key(self):
        # 冲突条件声明即以 MCLFeatureState 键名为前提（仅此一键有冲突规则）
        body = self._merge_body()
        self.assertIn('BOOL featureConflict = [key isEqualToString:@"MCLFeatureState"]', body)

    def test_conflict_requires_disk_false_and_live_true(self):
        # 磁盘 Found 且为 false、live Found 且为 true 才冲突；健康 disk=false/live=false 无冲突
        body = self._merge_body()
        self.assertIn("![values[key] boolValue]", body)
        self.assertIn("[liveValues[key] boolValue]", body)
        self.assertIn("values[key] != nil", body)
        self.assertIn("liveValues[key] != nil", body)

    def test_disk_branch_excludes_conflict_keys(self):
        body = self._merge_body()
        self.assertIn("diskState == CLMCLPrefFound && !featureConflict", body)

    def test_conflict_channel_label_reported(self):
        body = self._merge_body()
        self.assertIn('@"conflict_live_wins"', body)
        conflict_label = body.index('@"conflict_live_wins"')
        disk_label = body.index('@"disk"')
        self.assertLess(conflict_label, disk_label)  # 冲突标签优先于 disk/live/none


class MCLDomainFinalizationContractTests(unittest.TestCase):
    """任务 5.4（v1.17.2 域定案回灌，re-notes §7）：真实偏好域定案 + 活通道 exec 路径解析。

    真机轮 2 定案：MCL 六键真实域 = com.apple.smartcharging.topoffprotection
    （mobile 用户）——静态铁证（manager 单例工厂块 0x20236abd8 传给
    initWithDefaultsDomain: 的 CFString @0x2371fd2c0，参照物校验通过）+ 真机实锤
    （su mobile -c 'defaults read' 该域显示 MCLFeatureState=1 等）。候选域清单以
    topoffprotection 为首位，powerui 两域降为回退。
    roothide 下 daemon 视野不存在 /usr/bin/defaults（defaults_missing 实锤），活通道
    defaults 二进制须按序探测：jbroot 解析路径（运行时 dlsym 函数探测，编译期弱依赖
    roothide）→ /var/jb/usr/bin/defaults → /usr/bin/defaults，任一存在即用。
    """

    @classmethod
    def setUpClass(cls):
        cls.utils_mm = UTILS_MM.read_text()

    def _live_body(self):
        return function_body(self.utils_mm, "BOOL CLMCLReadPrefsLive(NSMutableDictionary* outLive, BOOL forceRefresh) {")

    def test_candidate_domains_topoffprotection_first_then_fallbacks(self):
        body = function_body(self.utils_mm, "static NSArray<NSString*>* CLMCLCandidateDomains(void) {")
        topoff = body.index('@"com.apple.smartcharging.topoffprotection"')
        charging = body.index('@"com.apple.powerui.smartcharging"')
        charge = body.index('@"com.apple.powerui.smartcharge"')
        self.assertLess(topoff, charging)   # 静态定案域居首
        self.assertLess(charging, charge)   # 回退域保持 smartcharging → smartcharge

    def test_candidate_domains_comment_points_to_renotes_7(self):
        body = function_body(self.utils_mm, "static NSArray<NSString*>* CLMCLCandidateDomains(void) {")
        self.assertIn("re-notes", body)

    def test_live_channel_probes_defaults_binary_jbroot_first(self):
        body = self._live_body()
        jbroot = body.index('resolveRoothidePathByAPI(@"/usr/bin/defaults")')
        var_jb = body.index('fileExistsAtPath:@"/var/jb/usr/bin/defaults"')
        plain = body.index('fileExistsAtPath:@"/usr/bin/defaults"')
        self.assertLess(jbroot, var_jb)   # jbroot 解析（dlsym 弱依赖）最先尝试
        self.assertLess(var_jb, plain)    # rootless bootstrap 次之，rootful 直通最后

    def test_live_channel_defaults_missing_only_after_all_candidates(self):
        body = self._live_body()
        jbroot = body.index('resolveRoothidePathByAPI(@"/usr/bin/defaults")')
        var_jb = body.index('fileExistsAtPath:@"/var/jb/usr/bin/defaults"')
        plain = body.index('fileExistsAtPath:@"/usr/bin/defaults"')
        missing = body.index('@"defaults_missing"')
        # 全部三级候选探测完毕才允许降级 defaults_missing
        self.assertLess(jbroot, missing)
        self.assertLess(var_jb, missing)
        self.assertLess(plain, missing)

    def test_spawn_helper_execs_probed_binary_path(self):
        body = function_body(self.utils_mm, "static int CLMCLSpawnDefaultsRead(NSString* defaultsPath, NSString* domain, NSMutableData* outData) {")
        self.assertIn("execl(defaultsPathC", body)

    def test_spawn_call_site_uses_resolved_binary(self):
        body = self._live_body()
        resolved = body.index("NSString* defaultsBin = nil;")
        spawn = body.index("CLMCLSpawnDefaultsRead(defaultsBin, domain, outData)")
        self.assertLess(resolved, spawn)  # 解析出的二进制路径传入 spawn


class MCLAcceptedUnverifiedAttributionContractTests(unittest.TestCase):
    """任务 5.4（v1.17.2 受理推断归因修正）：mcl_enabled=YES 时禁止归 gate1/gate2。

    F2：层2 内存标志（strb #1,[x19+0x14]）的置位代码在 gate1/gate2 之后——
    after.layer2.mcl_enabled=YES 即服务端已通过全部门禁并受理 enableMCL 的实锤。
    此时双通道无法证实 MCLFeatureState 只说明 cfprefsd 持久化证据不可得，不得自相
    矛盾地归 gate：报新分支 accepted_unverified + advice=charge_test_now；既有失败
    分支族与默认建议（reboot_and_retry）语义不变。App 侧识别 charge_test_now 输出
    「插电充电实测」提示，双语 strings 同步。
    """

    @classmethod
    def setUpClass(cls):
        cls.daemon_mm = DAEMON_MM.read_text()
        cls.adv_settings_m = ADV_SETTINGS_M.read_text()
        cls.strings_en = STRINGS_EN.read_text()
        cls.strings_zh = STRINGS_ZH.read_text()

    def _inner_body(self):
        return function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepairInner(void) {")

    def test_agent_memory_flag_guard_precedes_gate_attribution(self):
        # 层2 标志守卫位于 !featureWritten 分支内、gate 探测/归因之前
        body = self._inner_body()
        written = body.index("if (!featureWritten)")
        gate_probe = body.index("MCLProbeDeviceSupports80ChargeLimit()")
        guard_region = body[written:gate_probe]
        self.assertIn('[afterDiag[@"layer2"][@"mcl_enabled"] boolValue]', guard_region)
        self.assertIn('@"accepted_unverified"', guard_region)

    def test_accepted_unverified_advice_is_charge_test_now(self):
        body = self._inner_body()
        accepted = body.index('@"accepted_unverified"')
        advice = body.index('advice = @"charge_test_now"')
        self.assertLess(accepted, advice)   # 受理实锤分支携带 charge_test_now 建议

    def test_default_advice_and_existing_branch_family_unchanged(self):
        body = self._inner_body()
        for branch in ("call_error", "gate1_augury_feature", "gate2_device_gate",
                       "qmax_neutralized", "token_zero", "still_disconnected"):
            self.assertIn(f'@"{branch}"', body)   # 既有分支族语义不变
        self.assertIn('NSString* advice = @"reboot_and_retry";', body)  # 默认建议不变
        self.assertIn('@"advice": advice', body)                        # 失败报告携带 advice

    def test_app_result_message_recognizes_charge_test_now(self):
        body = function_body(self.adv_settings_m, "- (NSString *)mclRepairResultMessage:(NSDictionary *)result {")
        self.assertIn('@"charge_test_now"', body)

    def test_bilingual_strings_have_charge_test_now_entry(self):
        key = "服务端已受理并持久化尝试，请插电充电实测 80%。"
        self.assertIn(f'"{key}"', self.strings_en)
        self.assertIn(f'"{key}"', self.strings_zh)


class MCLExecutionLayerEvidenceContractTests(unittest.TestCase):
    """执行层物理证据（固件逆向 iPhone16,2 / iOS 17.1 21B80 定案）。

    固件逆向结论：MCL 的 80/101 值只在 engageManualChargeLimit 执行那一刻决定，
    之后 PowerUI 侧没有路径重新 evaluate；clearChargeLimit 会调
    IOPSLimitBatteryLevelCancel 取消 powerd 侧限制；isMCLCurrentlyEnabled 只读代理
    内存标志，与 powerd 里是否有生效限制无关。因此执行层证据不能只看注册表候选键
    （本轮实验候选键恒空），必须补一条不依赖猜键的物理电流通道。
    """

    @classmethod
    def setUpClass(cls):
        cls.daemon_mm = DAEMON_MM.read_text()

    def test_physical_evidence_helper_exists_and_samples_battery_info(self):
        body = function_body(self.daemon_mm, "static NSDictionary* MCLPhysicalExecutionEvidence(void) {")
        self.assertIn("getBatInfo(&info, YES)", body)          # 复用既有读路径，无新增 IO
        self.assertIn("@\"physical_current\"", body)            # 新证据等级
        self.assertIn("@\"conclusive\"", body)                  # 决定性判据显式标注
        self.assertIn("@\"physically_limited\"", body)
        self.assertIn("kMCLExecutionAmperageThresholdMA", body)  # 与第一阶段停充判定同一阈值
        self.assertIn("kMCLExecutionTriggerSoC", body)

    def test_threshold_matches_phase1_effective_criterion(self):
        # 第一阶段硬结论（iOS17-ChargeLimiter 逆向总结 §2.2-3）：有效停充用
        # Amperage/InstantAmperage 跨 120mA 判定，不看 bool。执行层沿用同一物理量。
        self.assertIn("static const NSInteger kMCLExecutionAmperageThresholdMA = 120;",
                      self.daemon_mm)
        self.assertIn("static const NSInteger kMCLExecutionTriggerSoC = 80;",
                      self.daemon_mm)

    def test_evidence_degrades_to_indirect_when_not_samplable(self):
        # 采样失败 / 缺属性 / 未插电 / 电量未到上限都不得给出 limited 结论，
        # 必须退回 indirect 或 conclusive=NO——否则会把「本来就不需要限制」当成脱节。
        body = function_body(self.daemon_mm, "static NSDictionary* MCLPhysicalExecutionEvidence(void) {")
        self.assertIn("@\"battery_info_unavailable\"", body)
        self.assertIn("@\"battery_properties_incomplete\"", body)
        self.assertIn("@\"not_externally_connected\"", body)
        self.assertIn("@\"soc_below_limit_trigger\"", body)

    def test_non_conclusive_evidence_never_claims_not_limited(self):
        # conclusive=NO 分支只设 note，不得置 physically_limited；默认值是 NSNull。
        # 否则「本来就不需要限制」（未插电 / 电量低于上限）会被误判成执行层脱节。
        body = function_body(self.daemon_mm, "static NSDictionary* MCLPhysicalExecutionEvidence(void) {")
        init_region = body[:body.index("NSDictionary* info = nil;")]
        self.assertIn('ev[@"physically_limited"] = [NSNull null];', init_region)
        self.assertIn('ev[@"conclusive"] = @NO;', init_region)
        # 只在 conclusive 分支内才写入 physically_limited / conclusive=YES，且写在其后
        conclusive_assign = body.index('ev[@"conclusive"] = @YES;')
        limited_assign = body.index('ev[@"physically_limited"] = @(limited);')
        self.assertLess(conclusive_assign, limited_assign)
        # conclusive=YES 与 limited 赋值都在同一个决定性 if 块内，且 limited 在后
        conclusive_if = body.rindex("if (externalConnected && reachedTrigger && current != nil) {", 0, conclusive_assign)
        self.assertLess(conclusive_if, conclusive_assign)
        self.assertLess(conclusive_assign, limited_assign)
        # 非决定性分支整段之后不得再出现 physically_limited 赋值
        else_note = body.index('NSString* note = externalConnected')
        self.assertNotIn('physically_limited", @(', body[else_note:])

    def test_layer3_standalone_composes_registry_and_physical(self):
        body = function_body(self.daemon_mm, "static NSDictionary* MCLLayer3EvidenceStandalone(void) {")
        self.assertIn("MCLRegistryEvidenceCandidateKeys()", body)   # 既有候选键路径保留
        self.assertIn("MCLPhysicalExecutionEvidence()", body)      # 物理通道注入
        self.assertIn('@"physical_current"', body)
        self.assertIn('@"indirect"', body)                          # 两者皆空仍如实退化
        self.assertIn('@"no_stable_registry_key"', body)

    def test_registry_diff_present_still_wins_over_physical(self):
        body = function_body(self.daemon_mm, "static NSDictionary* MCLLayer3EvidenceStandalone(void) {")
        registry_branch = body.index("if (hasCandidates && [registryEvidence[@\"present\"] boolValue]) {")
        physical_branch = body.index("if ([physical[@\"evidence_grade\"] isEqualToString:@\"physical_current\"]")
        self.assertLess(registry_branch, physical_branch)   # 键级证据优先

    def test_verdict_uses_physical_channel_for_row2(self):
        # 判定矩阵行 2（层1/层2 开但执行层未在限制）必须能被物理通道触发——否则受损设备
        # （偏好+代理内存全绿、实际充过头）仍会被误判 healthy_enabled。
        body = function_body(self.daemon_mm, "static NSString* MCLVerdictFromDiagnostics(BOOL mclSupported, NSDictionary* layer1, BOOL agentEnabled, NSDictionary* layer3) {")
        physical_gate = body.index('isEqualToString:@"physical_current"]')
        agent_gate = body.index("if (!agentEnabled) {")
        self.assertLess(agent_gate, physical_gate)              # 层2 判据仍在前
        gate_region = body[physical_gate:]
        self.assertIn('@"conclusive"', gate_region)
        self.assertIn('@"physically_limited"', gate_region)
        self.assertIn('return @"disconnected";', gate_region)
        # 两个返回之间：物理判据必须先于 registry_diff 退化判定
        self.assertLess(gate_region.index('return @"disconnected";'),
                        gate_region.index("if (registryDiff && !layer3Present)"))


class MCLReverseEngineeringClaimContractTests(unittest.TestCase):
    """锁固件逆向结论的边界，防止把「已证实」与「未证实/不可得」混写。

    这些断言都是 Verifier 复核（2026-09-28，只读验收）中发现注释越界后补的：
    能证实的写能证实的，证不到的不写结论。
    """

    @classmethod
    def setUpClass(cls):
        cls.daemon_mm = DAEMON_MM.read_text()

    def test_clearchargelimit_call_site_is_unplug_edge_only(self):
        # handleCallback 的拔电沿是唯一已证实的 clearChargeLimit 调用场合；
        # checkpoint ∈ {5,6} 的判定只决定是否进入主处理体，不是取消条件。
        self.assertIn("反汇编确认调用场合为 handleCallback 的**拔电沿**", self.daemon_mm)
        self.assertNotIn("电量跌出 checkpoint 5/6 时都会走", self.daemon_mm)

    def test_twenty_one_day_branch_overwrites_not_adds(self):
        # additionalWaitTimeWithProperties 越过 21 天线时直接覆写 99999.0，不是相加
        body = self.daemon_mm
        claim = "整体覆写**为 99999.0（不是相加）"
        self.assertIn(claim, body)

    def test_mcltargetsoc_documented_as_never_persisted(self):
        # mclTargetSoC 偏好键 PowerUI 从不写（engage 只赋 ivar，setMclTargetSoC: 无调用者）。
        # 必须留下这条边界，否则后来者会按字面去读一个恒缺失的键判定 101 中和。
        self.assertIn("mclTargetSoC 这个偏好键 PowerUI 从不写", self.daemon_mm)

    def test_token_selfheal_documented(self):
        self.assertIn("loadChargeLimitToken 在偏好键缺失时自行创建新 token 并回写",
                      self.daemon_mm)

    def test_branch_note_marks_powerd_vs_qmax_as_indistinguishable(self):
        # 第五轮真机定案更新：101 中和已可从偏好时间戳复算（MCLMitigationGateEvidence，
        # engage_neutralized_mitigation 分支），不可区分的收窄为 powerd-cancel 与
        # 官方窗口——不得把剩余两者混为一个确定性结论。
        body = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepairInner(void) {")
        gate = body.index("engage_neutralized_mitigation")
        fallback = body[gate:]
        self.assertIn("powerd charge limit cancelled", fallback)
        self.assertIn("official temp window re-engaged", fallback)
        # 中和命中时不得落入不可区分分支：gate 命中优先单列
        self.assertLess(gate, body.index('branch = @"execution_layer_not_limited";'))

    def test_mitigation_gate_recomputable_from_prefs(self):
        # 中和门必须只读偏好时间戳复算（DOD0/QMax/满充三阈值），不依赖 log stream。
        body = function_body(self.daemon_mm, "static NSDictionary* MCLMitigationGateEvidence(void) {")
        self.assertIn("259200.0", body)     # DOD0 3 天
        self.assertIn("1209600.0", body)    # QMax 14 天
        self.assertIn("50000.0", body)      # dod0AtLastQualQmax
        self.assertIn("108000.0", body)     # lastQualifiedQmaxDate 30h
        self.assertIn("1814400.0", body)    # 满充 21 天
        self.assertIn('@"will_neutralize"', body)

    def test_diagnostics_embed_mitigation_gate(self):
        body = function_body(self.daemon_mm, "static NSDictionary* collectMCLDiagnosticsWithLayer3(NSDictionary* layer3Override, BOOL forceRefresh) {")
        self.assertIn('report[@"mitigation_gate"] = MCLMitigationGateEvidence();', body)

    def test_qmax_subconditions_documented(self):
        self.assertIn("dod0AtLastQualQmax > 50000", self.daemon_mm)
        self.assertIn("lastQualifiedQmaxDate >= 108000s", self.daemon_mm)


class MCLMaintainContractTests(unittest.TestCase):
    """MCL 自动维持（固件逆向定案：系统侧无重新 evaluate 路径，必须外部对抗）。"""

    @classmethod
    def setUpClass(cls):
        cls.daemon_mm = DAEMON_MM.read_text()

    def test_maintain_helpers_defined(self):
        for sig in ("static BOOL mclMaintainShouldRun(void) {",
                    "static NSString* mclMaintainTick(void) {",
                    "static void refreshMCLMaintainTimer(void) {"):
            self.assertIn(sig, self.daemon_mm)

    def test_forward_declarations_exist_before_use(self):
        decl = self.daemon_mm.index("static void refreshMCLMaintainTimer(void);")
        body = self.daemon_mm.index("static void refreshMCLMaintainTimer(void) {")
        self.assertLess(decl, body)
        snap_decl = self.daemon_mm.index("static NSDictionary* mclMaintainRuntimeSnapshot(void);")
        snap_body = self.daemon_mm.index("static NSDictionary* mclMaintainRuntimeSnapshot(void) {")
        self.assertLess(snap_decl, snap_body)

    def test_uses_public_setting_toggle_selector_only(self):
        # 不得引入新的私有 selector；维持走 PowerUISmartChargeClient 的 enableMCL:
        # （= 系统设置里 80% 限制开关的同一个入口）。
        body = function_body(self.daemon_mm, "static NSString* mclMaintainTick(void) {")
        self.assertIn("CLMCLForceEnable()", body)
        self.assertNotIn("performSelector:", body)
        self.assertNotIn("NSSelectorFromString", body)

    def test_respects_user_choice_never_enables_mcl_on_its_own(self):
        # 维持器只在代理内存读回 MCL=YES 时动作：用户显式关掉（含 CL 永久停用）
        # 时 classify 为 off，一律不动——不得把用户的选择覆盖回去。
        body = function_body(self.daemon_mm, "static NSString* mclMaintainTick(void) {")
        guard = body.index("if (!getSmartChargeMCLEnabled()) {")
        force = body.index("CLMCLForceEnable()")
        self.assertLess(guard, force)
        guard_region = body[guard:force]
        self.assertIn('@"mcl_off_by_user"', guard_region)
        self.assertIn('return @"mcl_off_by_user";', guard_region)

    def test_toctou_recheck_before_force_enable(self):
        # 两次采样之间 MCL 可能刚被关掉：下发前必须再读一次，防止把用户选择覆盖回去。
        body = function_body(self.daemon_mm, "static NSString* mclMaintainTick(void) {")
        first = body.index("if (!getSmartChargeMCLEnabled()) {")
        recheck = body.rindex("if (!getSmartChargeMCLEnabled()) {")
        force = body.index("CLMCLForceEnable()")
        self.assertLess(first, recheck)
        self.assertLess(recheck, force)

    def test_false_positive_suppression_streak_and_cooldown(self):
        body = function_body(self.daemon_mm, "static NSString* mclMaintainTick(void) {")
        self.assertIn("kMCLMaintainNegativeStreakRequired", body)
        self.assertIn("kMCLMaintainCooldownSeconds", body)
        self.assertIn("cooling_down", body)
        self.assertGreaterEqual(kMCLMaintainNegativeStreakRequired_value(), 2)
        self.assertGreaterEqual(kMCLMaintainCooldownSeconds_value(),
                                kMCLMaintainIntervalSeconds_value())

    def test_pauses_during_coordination_and_full_charge_window(self):
        body = function_body(self.daemon_mm, "static NSString* mclMaintainTick(void) {")
        self.assertIn("g_tempSmartChargeDisabledByCL", body)
        self.assertIn("g_smartChargeCoordinationSessionID.length > 0", body)
        self.assertIn("g_fullChargeWindowActive", body)
        self.assertIn('@"full_charge_window_active"', body)

    def test_pauses_while_manual_repair_running(self):
        # 手动修复做前后快照/回滚，并发 tick 的写入可能落进它的回滚窗口——维持器必须让位。
        body = function_body(self.daemon_mm, "static NSString* mclMaintainTick(void) {")
        self.assertIn("g_mclRepairRunning", body)
        self.assertIn('@"repair_in_progress"', body)
        lock = function_body(self.daemon_mm, "static NSObject* MCLRepairLock(void) {")
        self.assertIn("lock", lock)

    def test_token_is_deliberately_not_gated_before_engage(self):
        # firmware 定案：loadChargeLimitToken 会自愈（键缺失时创建并回写），
        # 前置检查只会挡住唯一能恢复的那次 engage。此处锁的是「不 gate」这个决定本身，
        # 防止后来者按 A1 字面补一个 token 检查把自愈路径堵死。
        # 只查代码（剥掉 // 注释——注释里写明了这条决策）。
        body = function_body(self.daemon_mm, "static NSString* mclMaintainTick(void) {")
        code_only = "\n".join(l.split("//")[0] for l in body.split("\n"))
        engage_region = code_only[code_only.index("CLMCLForceEnable()") - 400:code_only.index("CLMCLForceEnable()")]
        self.assertNotIn('chargeLimitToken', engage_region)
        self.assertNotIn('CLMCLPrefKeys', engage_region)

    def test_only_acts_on_conclusive_evidence(self):
        body = function_body(self.daemon_mm, "static NSString* mclMaintainTick(void) {")
        conclusive = body.index('if (![evidence[@"conclusive"] boolValue]) {')
        self.assertIn('return @"not_applicable";',
                      body[conclusive:])
        healthy = body.index('if ([evidence[@"physically_limited"] boolValue]) {')
        self.assertLess(conclusive, healthy)

    def test_records_events_on_policy_timeline(self):
        body = function_body(self.daemon_mm, "static NSString* mclMaintainTick(void) {")
        self.assertIn('appendMCLRepairCoordinationEvent(@"mcl_maintain_re_engaged"', body)

    def test_diagnostics_report_embeds_maintain_snapshot(self):
        body = function_body(self.daemon_mm, "static NSDictionary* collectMCLDiagnosticsWithLayer3(NSDictionary* layer3Override, BOOL forceRefresh) {")
        self.assertIn('report[@"maintain"] = mclMaintainRuntimeSnapshot();', body)

    def test_timer_refresh_wired_into_config_lifecycle(self):
        # 配置加载 / enable / disable_smart_charge / mcl_auto_maintain 都要重排定时器，
        # 否则切换开关后定时器状态与配置不一致。
        loader = function_body(self.daemon_mm, "static void initConf(BOOL reset) {")
        self.assertIn("refreshMCLMaintainTimer();", loader)
        self.assertIn('@"mcl_auto_maintain": @NO', self.daemon_mm)   # 默认关闭：维持是可选兜底，不替用户驻留


    def test_maintain_switch_is_a_local_config_key(self):
        self.assertIn('getLocalBool(@"mcl_auto_maintain", NO)', self.daemon_mm)


def kMCLMaintainNegativeStreakRequired_value():
    import re
    m = re.search(r"kMCLMaintainNegativeStreakRequired = (\d+);", DAEMON_MM.read_text())
    assert m, "kMCLMaintainNegativeStreakRequired constant missing"
    return int(m.group(1))


def kMCLMaintainCooldownSeconds_value():
    import re
    m = re.search(r"kMCLMaintainCooldownSeconds = ([0-9.]+);", DAEMON_MM.read_text())
    assert m, "kMCLMaintainCooldownSeconds constant missing"
    return float(m.group(1))


def kMCLMaintainIntervalSeconds_value():
    import re
    m = re.search(r"kMCLMaintainIntervalSeconds = ([0-9.]+);", DAEMON_MM.read_text())
    assert m, "kMCLMaintainIntervalSeconds constant missing"
    return float(m.group(1))


class MCLExecutionLayerAttributionContractTests(unittest.TestCase):
    """修复失败归因新增 execution_layer_not_limited（执行层未在限制）。"""

    @classmethod
    def setUpClass(cls):
        cls.daemon_mm = DAEMON_MM.read_text()

    def test_new_branch_added_without_removing_existing_family(self):
        body = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepairInner(void) {")
        self.assertIn('@"execution_layer_not_limited"', body)
        for branch in ("call_error", "gate1_augury_feature", "gate2_device_gate",
                       "qmax_neutralized", "token_zero", "still_disconnected"):
            self.assertIn(f'@"{branch}"', body)

    def test_physical_check_precedes_qmax_and_token_branches(self):
        # 修复后即时采样物理电流：enableMCL 同步走到 IOPSLimitBatteryLevel，此刻仍未
        # 限制即为实证。它必须排在 qmax_neutralized / token_zero 之前（那两个依赖
        # 注册表 diff 与偏好键，在本轮候选键实验为空的前提下拿不到证据）。
        body = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepairInner(void) {")
        physical = body.index("MCLPhysicalExecutionEvidence();")
        qmax = body.index('branch = @"qmax_neutralized";')
        token = body.index('branch = @"token_zero";')
        self.assertLess(physical, qmax)
        self.assertLess(physical, token)

    def test_app_maps_new_branch_and_advice_bilingually(self):
        app = ADV_SETTINGS_M.read_text()
        body = function_body(app, "- (NSString *)mclRepairResultMessage:(NSDictionary *)result {")
        self.assertIn('@"execution_layer_not_limited"', body)
        self.assertIn('@"re_engage_and_observe"', body)
        for path in (STRINGS_EN, STRINGS_ZH):
            text = path.read_text()
            self.assertIn("执行层未生效：已插电且电量达到上限，但电流未被压低", text)
            self.assertIn("daemon 会自动重新下发", text)


class MCLTempWindowContractTests(unittest.TestCase):
    """官方临时停用窗口（第五阶段逆向定案）。

    固件：setTemporarilyDisabled:until:（0x20236f898）写 disabledUntil 偏好，
    defaultDateToDisableUntilGivenDate:（0x20236f70c）算成「下一个早上 6:00」；
    设置来源只有 client:setState:withHandler:（0x20237c400）case 2/3（= 客户端
    temporarilyEnableCharging / temporarilyDisableSmartCharging，通知「立即充电」
    按钮走 case 2）、initWithDefaults 恢复。窗口 active 期间 MCL 限制完全不执行，
    窗口结束或之后首个插件沿 handleCallback 自愈重新 engage。
    """

    @classmethod
    def setUpClass(cls):
        cls.daemon_mm = DAEMON_MM.read_text()

    def test_window_evidence_function_defined_with_firmware_addresses(self):
        self.assertIn("static NSDictionary* MCLTemporaryWindowEvidence(void) {", self.daemon_mm)
        body = function_body(self.daemon_mm, "static NSDictionary* MCLTemporaryWindowEvidence(void) {")
        # 只读 plist 直读（与 CLMCLReadPrefs 同一路径），无 XPC、无子进程
        self.assertIn("com.apple.smartcharging.topoffprotection.plist", body)
        self.assertIn('@"disabledUntil"', body)
        self.assertIn("timeIntervalSinceReferenceDate", body)
        # 键不在 F7 六键白名单内：只读诊断，不得混入写入路径
        self.assertNotIn("setNumber", body)
        self.assertNotIn("CFPreferencesSet", body)

    def test_maintain_tick_yields_to_window_before_physical_sampling(self):
        # 窗口 active 时不采样、不计数、不下发：让位发生在 negativeStreak += 1 之前。
        body = function_body(self.daemon_mm, "static NSString* mclMaintainTick(void) {")
        window = body.index("MCLTemporaryWindowEvidence()")
        active = body.index('if ([window[@"active"] boolValue]) {')
        user_guard = body.index("if (!getSmartChargeMCLEnabled()) {")
        sampling = body.index("MCLPhysicalExecutionEvidence();")
        self.assertLess(user_guard, window)
        self.assertLess(window, active)
        self.assertLess(active, sampling)
        region = body[active:sampling]
        self.assertIn('@"official_temp_window"', region)
        self.assertIn("return @"+"\"official_temp_window\";", region)
        self.assertNotIn("CLMCLForceEnable", region)

    def test_window_yield_resets_streak(self):
        # 窗口不是失效：负样本计数必须清零，否则窗口结束后残留计数会立即误触发重下发。
        body = function_body(self.daemon_mm, "static NSString* mclMaintainTick(void) {")
        active = body.index('if ([window[@"active"] boolValue]) {')
        region = body[active:body.index("NSDictionary* evidence = MCLPhysicalExecutionEvidence();", active)]
        self.assertIn("g_mclMaintainNegativeStreak = 0;", region)
        self.assertIn('mclMaintainRecordState(@"official_temp_window", window, @"none");', region)

    def test_diagnostics_report_embeds_window_evidence(self):
        body = function_body(self.daemon_mm, "static NSDictionary* collectMCLDiagnosticsWithLayer3(NSDictionary* layer3Override, BOOL forceRefresh) {")
        self.assertIn('report[@"temporary_window"] = MCLTemporaryWindowEvidence();', body)

    def test_attribution_note_lists_window_as_third_cause(self):
        # 修复归因 execution_layer_not_limited 的注记必须把「官方窗口重新设置」列为
        # 第三候选，避免把窗口行为误报成 powerd cancel。
        body = function_body(self.daemon_mm, "static NSDictionary* performMCLLimitRepairInner(void) {")
        self.assertIn("official temp window re-engaged", body)
        self.assertIn("Feature disabled until:", body)

    def test_whitelist_six_keys_untouched(self):
        # disabledUntil 只作只读诊断扩展：F7 六键白名单不得被扩写（写入面不膨胀）。
        body = function_body(UTILS_MM.read_text(), "NSArray<NSString*>* CLMCLPrefKeys(void) {")
        self.assertNotIn("disabledUntil", body)


class MCLExecutionWindowContractTests(unittest.TestCase):
    """执行层观测窗口 [80, 95]（真机 2026-09-29 回灌：100% 满电自然停充电流 81mA
    被误判 physically_limited=true、verdict 假绿——满电态低电流判不出 MCL 好坏）。"""

    @classmethod
    def setUpClass(cls):
        cls.daemon_mm = DAEMON_MM.read_text()

    def test_window_max_constant_defined(self):
        self.assertIn("kMCLExecutionWindowSoCMax = 95;", self.daemon_mm)

    def test_physical_judgment_bounded_by_window(self):
        body = function_body(self.daemon_mm, "static NSDictionary* MCLPhysicalExecutionEvidence(void) {")
        self.assertIn("soc <= kMCLExecutionWindowSoCMax", body)
        # 超窗必须 conclusive=NO + 专属 note，不得给「生效」结论
        self.assertIn('@"soc_above_mcl_window_full_charge"', body)

    def test_above_window_note_not_claiming_limited(self):
        # 常量与注释在函数体外（文件作用域），查全文；理由注释在常量定义前面
        window = self.daemon_mm.index("kMCLExecutionWindowSoCMax = 95")
        self.assertIn("满电自然停充", self.daemon_mm[max(0, window - 300):window])
