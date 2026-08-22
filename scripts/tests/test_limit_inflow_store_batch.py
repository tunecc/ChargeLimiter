import re
import unittest
from pathlib import Path

UTILS = (Path(__file__).resolve().parents[2] / "ChargeLimiter" / "utils.mm").read_text(
    encoding="utf-8"
)


class TestLimitInflowStoreBatch(unittest.TestCase):
    """CLSettingsStore 批量写入口"""

    def test_batch_write_method_exists(self):
        self.assertIn("- (BOOL)setValuesForKeys:(NSDictionary*)keyValues apply:(BOOL)doApply", UTILS)

    def test_batch_write_uses_synchronized(self):
        m = re.search(
            r"- \(BOOL\)setValuesForKeys:\(NSDictionary\*\)keyValues apply:\(BOOL\)doApply \{(.*?)\n\}",
            UTILS,
            re.S,
        )
        self.assertIsNotNone(m)
        body = m.group(1)
        self.assertIn("@synchronized", body)

    def test_batch_write_calls_apply(self):
        m = re.search(
            r"- \(BOOL\)setValuesForKeys:\(NSDictionary\*\)keyValues apply:\(BOOL\)doApply \{(.*?)\n\}",
            UTILS,
            re.S,
        )
        self.assertIsNotNone(m)
        body = m.group(1)
        self.assertIn("apply", body)

    def test_batch_write_rollback_on_failure(self):
        m = re.search(
            r"- \(BOOL\)setValuesForKeys:\(NSDictionary\*\)keyValues apply:\(BOOL\)doApply \{(.*?)\n\}",
            UTILS,
            re.S,
        )
        self.assertIsNotNone(m)
        body = m.group(1)
        self.assertIn("reloadFromDisk", body)

    def test_c_bridge_batch_exists(self):
        self.assertIn("setlocalKVBatch_C", UTILS)


if __name__ == "__main__":
    unittest.main()
