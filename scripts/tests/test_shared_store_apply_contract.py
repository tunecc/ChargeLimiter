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


if __name__ == "__main__":
    unittest.main()
