"""只使用合成的描述文件验证发布配置，不读取本机凭据。"""
import datetime
import plistlib
import unittest

from ios_signing import BUNDLE, export_options


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.profile = {
            "UUID": "c230e9f4-011e-4a45-839e-5e668720cc3a",
            "TeamIdentifier": ["TESTTEAM01"],
            "ExpirationDate": datetime.datetime.now(datetime.UTC).replace(tzinfo=None) + datetime.timedelta(days=30),
            "Entitlements": {"application-identifier": f"TESTTEAM01.{BUNDLE}",
                             "aps-environment": "production", "get-task-allow": False,
                             "beta-reports-active": True},
        }

    def test_export_maps_app_profile_and_restricts_internal_testing(self):
        # 经 plist 序列化后仍是 Xcode 接受的布尔值及 UUID 映射。
        options = plistlib.loads(plistlib.dumps(export_options(self.profile)))
        self.assertEqual(options["provisioningProfiles"],
                         {BUNDLE: "c230e9f4-011e-4a45-839e-5e668720cc3a"})
        self.assertIs(options["testFlightInternalTestingOnly"], True)
        self.assertIs(options["manageAppVersionAndBuildNumber"], False)

    def test_preserves_apple_profile_uuid_case(self):
        # Xcode 按原始 UUID 匹配描述文件，不能规范化为大写或小写。
        for identifier in ["baB9b175-75e0-4688-9402-a4e6735107aa", "BAB9B175-75E0-4688-9402-A4E6735107AA"]:
            self.profile["UUID"] = identifier
            with self.subTest(identifier=identifier):
                options = export_options(self.profile)
                self.assertEqual(options["provisioningProfiles"][BUNDLE], identifier)

    def test_rejects_other_app(self):
        self.profile["Entitlements"]["application-identifier"] = "TESTTEAM01.org.example.other"
        with self.assertRaisesRegex(ValueError, "应用标识"):
            export_options(self.profile)

    def test_rejects_development_adhoc_and_enterprise_profiles(self):
        for change in ({"ProvisionedDevices": ["synthetic-device"]}, {"ProvisionsAllDevices": True}):
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, "App Store"):
                export_options(self.profile | change)
        self.profile["Entitlements"]["get-task-allow"] = True
        with self.assertRaisesRegex(ValueError, "App Store"):
            export_options(self.profile)

    def test_rejects_sandbox_push(self):
        self.profile["Entitlements"]["aps-environment"] = "development"
        with self.assertRaisesRegex(ValueError, "正式环境推送"):
            export_options(self.profile)

    def test_rejects_expired_profile(self):
        self.profile["ExpirationDate"] = datetime.datetime(2020, 1, 1)
        with self.assertRaisesRegex(ValueError, "过期"):
            export_options(self.profile)


if __name__ == "__main__":
    unittest.main()
