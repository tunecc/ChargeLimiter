# scripts/tests/test_shared_store_apply_contract.py
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
UTILS = REPO / "ChargeLimiter" / "utils.mm"
UTILS_H = REPO / "ChargeLimiter" / "utils.h"


class SharedStoreApplyContractTests(unittest.TestCase):
    def test_apply_returns_bool(self):
        s = UTILS.read_text(encoding="utf-8")
        self.assertRegex(s, r"- \(BOOL\)apply\b")

    def test_setlocalkv_checked_declared(self):
        h = UTILS_H.read_text(encoding="utf-8")
        self.assertIn("setlocalKVChecked", h)

    def test_write_success_repairs_ownership_hooks(self):
        s = UTILS.read_text(encoding="utf-8")
        # 写成功路径必须尝试把配置文件交回 mobile
        self.assertTrue(
            "repairSharedConfigFileOwnership" in s
            or ("chown" in s and "mobile" in s and "0640" in s),
            "successful shared config write must repair mobile ownership",
        )

    def test_apply_failure_restores_memory_from_disk(self):
        """apply 写失败后内存必须回滚到磁盘一致状态。

        setValue 会先改 preferences；若 apply 写盘失败仍保留脏内存，
        setlocalKVChecked 返回 NO 时 UI 会读到未落盘的值。契约：
        apply 失败路径必须 reloadFromDisk（或等价从磁盘重建 preferences）
        并清 dirty。
        """
        s = UTILS.read_text(encoding="utf-8")
        # 定位实现体（跳过 @interface 声明）
        impl_idx = s.find("@implementation CLSettingsStore")
        self.assertGreater(impl_idx, -1, "CLSettingsStore implementation must exist")
        apply_idx = s.find("- (BOOL)apply", impl_idx)
        self.assertGreater(apply_idx, impl_idx, "CLSettingsStore apply must exist")
        # apply 之后到 reloadFromDisk 方法定义前
        next_method = s.find("- (void)reloadFromDisk", apply_idx + 1)
        self.assertGreater(next_method, apply_idx)
        apply_body = s[apply_idx:next_method]

        # 失败路径：write 失败后 return NO 之前必须恢复内存
        self.assertIn("return NO", apply_body)
        # 写失败分支应调用 reloadFromDisk，或 readConfigDictionaryFromDisk 后重建 preferences
        restored = (
            "[self reloadFromDisk]" in apply_body
            or "reloadFromDisk" in apply_body
            or (
                "readConfigDictionaryFromDisk" in apply_body
                and "preferences" in apply_body
                and "return NO" in apply_body
            )
        )
        self.assertTrue(
            restored,
            "apply failure path must reloadFromDisk or rebuild preferences from disk",
        )


if __name__ == "__main__":
    unittest.main()
