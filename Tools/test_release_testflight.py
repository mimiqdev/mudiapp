"""Pure-logic unit tests for Tools/release-testflight.py.

No network, no signing, no Xcode: App Store Connect, `security` and
`codesign` are mocked. Run from the repository root:

    python3 Tools/test_release_testflight.py
"""

import importlib.util
import json
import plistlib
import tempfile
import unittest
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "release_testflight", Path(__file__).with_name("release-testflight.py"))
if spec is None or spec.loader is None:
    raise RuntimeError("Cannot load Tools/release-testflight.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

AT = datetime(2026, 9, 23, 9, tzinfo=timezone.utc)
TEAM = "Z8PD946Y4P"


def app_store_profile(bundle_id=release.APP_BUNDLE_ID, team=TEAM, **overrides):
    """Fixture App Store profile bytes, shaped like a decoded .mobileprovision."""
    profile = {
        "Name": "Mudi App Store",
        "UUID": "11111111-2222-3333-4444-555555555555",
        "TeamIdentifier": [team],
        "Entitlements": {
            "application-identifier": team + "." + bundle_id,
            "get-task-allow": False,
        },
        "DeveloperCertificates": [b"certificate"],
    }
    profile.update(overrides)
    return plistlib.dumps(profile)


def security_output(payload=None, returncode=0):
    return SimpleNamespace(returncode=returncode, stdout=payload or b"", stderr=b"")


def ipa_info(**overrides):
    info = {
        "CFBundleIdentifier": release.APP_BUNDLE_ID,
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "26092309",
        "ITSAppUsesNonExemptEncryption": False,
    }
    info.update(overrides)
    return info


def write_ipa(path, info, app_name="Mudi"):
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(f"Payload/{app_name}.app/Info.plist", plistlib.dumps(info))
    return path


class BuildNumberTests(unittest.TestCase):
    def test_uses_utc_yymmddhh_and_only_compares_current_marketing_version(self):
        visible = [("0.1.0", "1"), ("0.1.0", "2"), ("0.2.0", "99999999")]
        self.assertEqual(release.next_build_number(visible, "0.1.0", now=AT), 26092309)

    def test_first_upload_uses_timestamp(self):
        self.assertEqual(release.next_build_number([], "0.1.0", now=AT), 26092309)

    def test_timestamp_follows_utc_not_local_time(self):
        # 2026-09-23 01:30 +08:00 is 2026-09-22 17:30 UTC.
        local = datetime(2026, 9, 23, 1, 30, tzinfo=timezone(timedelta(hours=8)))
        self.assertEqual(release.next_build_number([], "0.1.0", now=local), 26092217)

    def test_later_hour_is_greater_than_visible_build(self):
        visible = [("0.1.0", "26092309")]
        self.assertEqual(release.next_build_number(visible, "0.1.0", now=AT + timedelta(hours=1)), 26092310)

    def test_same_hour_fails_instead_of_incrementing(self):
        with self.assertRaisesRegex(release.ReleaseError, "wait until a later UTC hour"):
            release.next_build_number([("0.1.0", "26092309")], "0.1.0", now=AT)

    def test_higher_visible_build_fails(self):
        with self.assertRaises(release.ReleaseError):
            release.next_build_number([("0.1.0", "26092310")], "0.1.0", now=AT)

    def test_noninteger_version_refuses_to_guess(self):
        with self.assertRaises(release.ReleaseError):
            release.next_build_number([("0.1.0", "1.2")], "0.1.0", now=AT)


class ReleaseConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.files = {name: self.root / name for name in
                      ("key.p8", "cert.p12", "password", "profile.mobileprovision")}
        for path in self.files.values():
            path.write_text("test-password\n")
            path.chmod(0o600)
        self.config_file = self.root / "TestFlight.local.json"
        self.write_config()
        self.config_file.chmod(0o600)

    def write_config(self, **overrides):
        config = {
            "apiKeyId": "TESTKEY",
            "issuerId": "TESTISSUER",
            "apiKeyPath": str(self.files["key.p8"]),
            "distributionP12Path": str(self.files["cert.p12"]),
            "distributionP12PasswordFile": str(self.files["password"]),
            "appStoreProfilePath": str(self.files["profile.mobileprovision"]),
        }
        config.update(overrides)
        self.config_file.write_text(json.dumps(config))

    def test_reads_paths_and_password_file(self):
        config = release.release_config(self.config_file)
        self.assertEqual(config["apiKeyId"], "TESTKEY")
        self.assertEqual(config["issuerId"], "TESTISSUER")
        self.assertEqual(config["p12Password"], "test-password")
        self.assertEqual(config["distributionP12Path"], self.files["cert.p12"].resolve())

    def test_refuses_missing_config(self):
        with self.assertRaisesRegex(release.ReleaseError, "TestFlight.local.json.example"):
            release.release_config(self.root / "absent.json")

    def test_refuses_incomplete_config(self):
        self.write_config(issuerId="")
        with self.assertRaises(release.ReleaseError):
            release.release_config(self.config_file)

    def test_refuses_missing_signing_file(self):
        self.files["cert.p12"].unlink()
        with self.assertRaisesRegex(release.ReleaseError, "Missing signing file"):
            release.release_config(self.config_file)

    def test_refuses_group_readable_config_or_secret_files(self):
        self.config_file.chmod(0o644)
        with self.assertRaises(release.ReleaseError):
            release.release_config(self.config_file)
        self.config_file.chmod(0o600)
        for name in ("cert.p12", "password", "key.p8"):
            path = self.files[name]
            path.chmod(0o640)
            with self.assertRaises(release.ReleaseError):
                release.release_config(self.config_file)
            path.chmod(0o600)

    def test_profile_is_not_required_to_be_600(self):
        # Profiles are not secrets; `security cms` only reads them.
        self.files["profile.mobileprovision"].chmod(0o644)
        self.assertEqual(release.release_config(self.config_file)["apiKeyId"], "TESTKEY")

    def test_refuses_signing_files_inside_repository(self):
        with (
            patch.object(release, "ROOT", self.root.resolve()),
            self.assertRaisesRegex(release.ReleaseError, "outside the repository"),
        ):
            release.release_config(self.config_file)

    def test_refuses_empty_password_file(self):
        self.files["password"].write_text("\n")
        with self.assertRaisesRegex(release.ReleaseError, "Empty distribution"):
            release.release_config(self.config_file)


class ProfileDetailsTests(unittest.TestCase):
    profile = Path("profile.mobileprovision")

    def assert_details(self, payload, **kwargs):
        with patch.object(release.subprocess, "run", return_value=security_output(payload, **kwargs)):
            return release.profile_details(self.profile)

    def assert_refused(self, payload, message=None, **kwargs):
        with patch.object(release.subprocess, "run", return_value=security_output(payload, **kwargs)):
            if message:
                with self.assertRaisesRegex(release.ReleaseError, message):
                    release.profile_details(self.profile)
            else:
                with self.assertRaises(release.ReleaseError):
                    release.profile_details(self.profile)

    def test_accepts_app_store_distribution_profile(self):
        profile, team = self.assert_details(app_store_profile())
        self.assertEqual(team, TEAM)
        self.assertEqual(profile["Name"], "Mudi App Store")

    def test_refuses_profile_without_explicit_get_task_allow_false(self):
        self.assert_refused(app_store_profile(), "not an App Store distribution profile")

    def test_refuses_profile_with_provisioned_devices(self):
        self.assert_refused(app_store_profile(ProvisionedDevices=["00008150-001265CE0E99401C"]))

    def test_refuses_profile_with_get_task_allow_true(self):
        entitlements = {
            "application-identifier": TEAM + "." + release.APP_BUNDLE_ID,
            "get-task-allow": True,
        }
        self.assert_refused(app_store_profile(Entitlements=entitlements))

    def test_refuses_profile_for_another_bundle_id(self):
        self.assert_refused(app_store_profile(bundle_id="com.mimiqdev.bolang"), release.APP_BUNDLE_ID)

    def test_refuses_undecodable_profile(self):
        self.assert_refused(None, "Cannot decode", returncode=1)


class VerifyIPATests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.ipa = Path(self.temp.name) / "Mudi.ipa"

    def verify(self, ipa):
        release.verify_ipa(ipa, "1.0", "26092309", TEAM)

    def test_refuses_wrong_bundle_id_or_version(self):
        payloads = (ipa_info(CFBundleIdentifier="com.mimiqdev.bolang"),
                    ipa_info(CFBundleShortVersionString="9.9"),
                    ipa_info(CFBundleVersion="1"))
        for info in payloads:
            write_ipa(self.ipa, info)
            with self.assertRaisesRegex(release.ReleaseError, "unexpected ID, version, build"):
                self.verify(self.ipa)

    def test_refuses_missing_or_true_compliance_declaration(self):
        without_key = ipa_info()
        del without_key["ITSAppUsesNonExemptEncryption"]
        for payload in (without_key, ipa_info(ITSAppUsesNonExemptEncryption=True)):
            write_ipa(self.ipa, payload)
            with self.assertRaises(release.ReleaseError):
                self.verify(self.ipa)

    def test_refuses_ipa_without_mudi_payload(self):
        write_ipa(self.ipa, ipa_info(), app_name="Bolang")
        with self.assertRaisesRegex(release.ReleaseError, "Payload/Mudi.app"):
            self.verify(self.ipa)

    def test_verifies_matching_ipa_with_local_codesign_and_embedded_profile(self):
        write_ipa(self.ipa, ipa_info())
        calls = []

        def record(argv, log=None):
            calls.append(argv)
            return ""

        signature = "Authority=Apple Distribution: Mimikyu Dev\nTeamIdentifier=" + TEAM + "\n"
        with (
            patch.object(release, "command", side_effect=record),
            patch.object(release, "profile_details", return_value=({"Name": "Mudi App Store"}, TEAM)),
            patch.object(release.subprocess, "run",
                         return_value=SimpleNamespace(returncode=0, stdout="", stderr=signature)),
        ):
            self.verify(self.ipa)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0], ["codesign", "--verify", "--deep", "--strict", calls[0][-1]])
        self.assertTrue(calls[0][-1].endswith("Payload/Mudi.app"))

    def test_refuses_ipa_signed_by_another_team(self):
        write_ipa(self.ipa, ipa_info())
        signature = "Authority=Apple Distribution: Mimikyu Dev\nTeamIdentifier=" + TEAM + "\n"
        with (
            patch.object(release, "command", return_value=""),
            patch.object(release, "profile_details", return_value=({"Name": "Mudi App Store"}, "OTHERTEAM")),
            patch.object(release.subprocess, "run",
                         return_value=SimpleNamespace(returncode=0, stdout="", stderr=signature)),
            self.assertRaisesRegex(release.ReleaseError, "another team"),
        ):
            self.verify(self.ipa)

    def test_refuses_ipa_without_apple_distribution_signature(self):
        write_ipa(self.ipa, ipa_info())
        with (
            patch.object(release, "command", return_value=""),
            patch.object(release.subprocess, "run", return_value=SimpleNamespace(
                returncode=1, stdout="", stderr="code object is not signed at all")),
            self.assertRaisesRegex(release.ReleaseError, "not signed locally"),
        ):
            self.verify(self.ipa)


class AppStoreConnectTests(unittest.TestCase):
    def test_altool_token_on_stderr(self):
        expected = "eyJheader" + ".eyJpayload.signature"
        with patch.object(release.subprocess, "run", return_value=SimpleNamespace(
                returncode=0, stdout="", stderr="Info: " + expected)):
            self.assertEqual(release.jwt("key", "issuer", Path("key.p8")), expected)

    def test_requires_internal_auto_access_group(self):
        app = {"data": [{"id": "app-id"}]}
        group = {"data": [{"id": "group-id", "attributes": {"name": release.TESTFLIGHT_GROUP,
                                                           "isInternalGroup": True,
                                                           "hasAccessToAllBuilds": False}}]}
        with (
            patch.object(release, "asc_get", side_effect=[app, group]),
            self.assertRaises(release.ReleaseError),
        ):
            release.lookup_build_number("token", "1.0")

    def test_requires_exactly_one_app_for_the_bundle_id(self):
        with (
            patch.object(release, "asc_get", return_value={"data": []}),
            self.assertRaisesRegex(release.ReleaseError, release.APP_BUNDLE_ID),
        ):
            release.lookup_build_number("token", "1.0")


if __name__ == "__main__":
    unittest.main()
