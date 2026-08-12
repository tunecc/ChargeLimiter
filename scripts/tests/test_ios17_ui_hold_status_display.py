import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SETTINGS_PATH = REPO_ROOT / "ChargeLimiter" / "UIKit" / "Controllers" / "CLSettingsViewController.m"


class Ios17UiHoldStatusDisplayTests(unittest.TestCase):
    def setUp(self):
        self.source = SETTINGS_PATH.read_text(encoding="utf-8")

    def _looks_charging_body(self) -> str:
        # Prefer the definition body (with opening brace), not the forward decl.
        marker = "static BOOL CLManagerLooksChargingForDisplay(CLBatteryManager *manager) {"
        start = self.source.find(marker)
        if start < 0:
            # Tolerate newline before brace
            start = self.source.find("static BOOL CLManagerLooksChargingForDisplay(CLBatteryManager *manager)")
            self.assertGreater(start, -1, "CLManagerLooksChargingForDisplay missing")
            brace = self.source.find("{", start)
            self.assertGreater(brace, start)
            # Skip pure forward-decl if first hit has no nearby body
            semi = self.source.find(";", start)
            if 0 <= semi < brace:
                start = self.source.find(
                    "static BOOL CLManagerLooksChargingForDisplay(CLBatteryManager *manager)",
                    semi + 1,
                )
                self.assertGreater(start, -1)
                brace = self.source.find("{", start)
            start = brace  # body from opening brace is fine for content asserts
        end = self.source.find("static BOOL CLManagerLooksDischargingForDisplay", start)
        self.assertGreater(end, start)
        return self.source[start:end]

    def test_looks_charging_does_not_trust_is_charging_alone(self):
        """iOS17 sticky IsCharging=true must not alone force '正在充电'."""
        body = self._looks_charging_body()
        # Must gate IsCharging with charge command / current, not bare OR.
        self.assertNotIn(
            "return manager.isCharging || manager.holdCharging || current > CLDisplayChargingThresholdmA;",
            body,
        )
        self.assertIn("chargeCommandEnabled", body)
        self.assertIn("current > CLDisplayChargingThresholdmA", body)

    def test_looks_charging_respects_hold_and_inhibit(self):
        body = self._looks_charging_body()
        self.assertIn("manager.holdActive", body)
        self.assertIn("manager.predictiveChargingInhibitActive", body)
        self.assertIn('@"hold"', body)
        self.assertIn('@"stopped"', body)

    def test_display_state_uses_charging_display_helper(self):
        # iOS17：充电显示态走 CLManagerLooksChargingForDisplay，不用 raw manager.isCharging。
        # （write-only 的 statusView.isCharging 已删；helper 现在在 CLDisplayedPowerStateForManager 里驱动显示态）
        start = self.source.find("static NSString *CLDisplayedPowerStateForManager(CLBatteryManager *manager) {")
        self.assertGreater(start, -1)
        end = self.source.find("static BOOL CLDisplayedPowerStateUsesExternalPower", start)
        body = self.source[start:end]
        self.assertIn("CLManagerLooksChargingForDisplay(manager)", body)
        self.assertNotIn("manager.isCharging", body)

    def test_power_state_label_still_maps_hold_and_stopped(self):
        start = self.source.find("- (NSString *)powerStateLabelForManager:(CLBatteryManager *)manager")
        end = self.source.find("- (NSString *)chargeCommandLabelForManager:", start)
        body = self.source[start:end]
        self.assertIn('@"hold"', body)
        self.assertIn("插电保持中", body)
        self.assertIn('@"stopped"', body)
        self.assertIn("已连接电源 · 停止充电", body)


if __name__ == "__main__":
    unittest.main()
