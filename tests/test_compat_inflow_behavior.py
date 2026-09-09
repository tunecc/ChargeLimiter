from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CONTROLLER = ROOT / "ChargeLimiter/UIKit/Controllers/CLBatteryCompatibilityTestViewController.m"


class CompatInflowBehaviorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="cl-compat-behavior-")
        cls.addClassCleanup(cls.temp.cleanup)
        directory = Path(cls.temp.name)
        source = CONTROLLER.read_text(encoding="utf-8")
        # Compile the production engine unchanged, omitting only the UIKit sections.
        types = source[source.index("typedef NS_ENUM"):source.index("static void *kCLCompatRowHandlerKey")]
        engine = source[source.index("@interface CLBatteryCompatibilityEngine :"):
                        source.index("@interface CLBatteryCompatibilityTestViewController ()")]
        harness = (ROOT / "tests/compat_inflow_behavior.m").read_text(encoding="utf-8")
        generated = directory / "compat_inflow_behavior.m"
        generated.write_text(harness.replace("/* PRODUCTION_ENGINE */", types + engine), encoding="utf-8")
        cls.binary = directory / "compat_inflow_behavior"
        result = subprocess.run(
            ["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks",
             "-framework", "Foundation", "-Wno-nullability-completeness",
             "-o", str(cls.binary), str(generated)],
            capture_output=True, text=True, timeout=60,
        )
        if result.returncode:
            raise AssertionError(f"Engine harness compilation failed:\n{result.stderr}")

    def check_scenario(self, name):
        result = subprocess.run([str(self.binary), name], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_cycle_does_not_depend_on_current(self):
        self.check_scenario("cycle")

    def test_current_and_external_state_cannot_replace_charging_exit(self):
        self.check_scenario("no_exit")

    def test_exit_at_deadline_can_still_complete(self):
        self.check_scenario("deadline_exit")

    def test_explicit_release_completes_cycle(self):
        self.check_scenario("release")

    def test_release_response_precedes_verdict(self):
        self.check_scenario("release_pending")

    def test_failed_release_is_one_error_even_after_observed_return(self):
        self.check_scenario("release_error")

    def test_release_timeout_reports_incomplete_cycle(self):
        self.check_scenario("release_timeout")

    def test_late_release_response_cannot_repeat_verdict(self):
        self.check_scenario("late_release")

    def test_late_sample_cannot_repeat_verdict(self):
        self.check_scenario("late_sample")

    def test_previous_test_poll_cannot_enter_next_test(self):
        self.check_scenario("stale_poll")

    def test_missing_or_malformed_charging_state_is_not_false(self):
        self.check_scenario("invalid_state")

    def test_cancel_drains_release_and_emits_no_verdict(self):
        self.check_scenario("cancel")

    def test_stop_charge_keeps_current_based_verdict(self):
        self.check_scenario("stop_charge")


if __name__ == "__main__":
    unittest.main()
