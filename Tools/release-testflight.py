#!/usr/bin/env python3
"""Build and optionally upload Mudi to TestFlight with local distribution signing.

The App Store Connect app is "Mudi for Herdr" (dev.mudi.mobile). A temporary
keychain holds the Apple Distribution identity during the build. The default
validates the IPA; --upload also publishes it to the internal group.
"""

import argparse
import hashlib
import json
import plistlib
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = "Mudi.xcodeproj"
SCHEME = "Mudi"
APP_NAME = "Mudi"
APP_BUNDLE_ID = "dev.mudi.mobile"
ASC_APP_NAME = "Mudi for Herdr"
TESTFLIGHT_GROUP = "Mudi Internal"


class ReleaseError(Exception):
    pass


def command(argv, *, log=None):
    if log is None:
        result = subprocess.run(argv, cwd=ROOT, text=True, capture_output=True)
        if result.returncode:
            raise ReleaseError(f"{argv[0]} failed ({result.returncode}): {result.stderr.strip()[-800:]}")
        return result.stdout
    try:
        with open(log, "w") as output:
            result = subprocess.run(argv, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
    except OSError as error:
        raise ReleaseError(f"Cannot run {argv[0]} with log {log}: {error}") from error
    if result.returncode:
        lines = Path(log).read_text(errors="replace").splitlines()
        raise ReleaseError(f"{argv[0]} failed ({result.returncode}); log: {log}\n" + "\n".join(lines[-20:]))
    return ""


def app_build_settings():
    output = command(["xcodebuild", "-project", PROJECT, "-scheme", SCHEME,
                      "-configuration", "Release", "-showBuildSettings"])

    def get(name):
        match = re.search(rf"^\s+{name} = (\S+)$", output, re.MULTILINE)
        if not match:
            raise ReleaseError(f"Missing Xcode build setting: {name}")
        return match.group(1)
    if get("PRODUCT_BUNDLE_IDENTIFIER") != APP_BUNDLE_ID:
        raise ReleaseError("App bundle ID does not match the expected TestFlight app")
    return get("MARKETING_VERSION")


def jwt(key_id, issuer_id, key_path):
    result = subprocess.run(["xcrun", "altool", "--generate-jwt", "--apiKey", key_id,
                             "--apiIssuer", issuer_id, "--p8-file-path", str(key_path)],
                            cwd=ROOT, text=True, capture_output=True)
    # altool writes the token to stderr on some Xcode versions. Never print it.
    match = re.search(r"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+",
                      result.stdout + "\n" + result.stderr)
    if result.returncode or not match:
        raise ReleaseError("altool could not generate an API token")
    return match.group(0)


def asc_json(url, token):
    """GET one App Store Connect JSON resource, refusing non-HTTPS URLs."""
    if urllib.parse.urlsplit(url).scheme != "https":
        raise ReleaseError("Refusing non-HTTPS App Store Connect URL: " + url)
    request = urllib.request.Request(  # noqa: S310 -- URL scheme checked above
        url, headers={"Authorization": "Bearer " + token, "Accept": "application/json"})
    try:
        # The scheme is checked above, so urlopen only sees the documented API
        # host or a pagination link Apple returned over HTTPS.
        with urllib.request.urlopen(request, timeout=30) as response:  # noqa: S310
            return json.load(response)
    except urllib.error.HTTPError as error:
        try:
            details = [(e.get("code"), e.get("title")) for e in json.load(error).get("errors", [])]
        except (ValueError, OSError):
            details = []
        raise ReleaseError(f"App Store Connect {url}: HTTP {error.code}, {details}") from error
    except (ValueError, OSError) as error:
        raise ReleaseError(f"App Store Connect {url}: unreadable response ({error})") from error


def asc_get(path, params, token):
    url = "https://api.appstoreconnect.apple.com/v1/" + path + "?" + urllib.parse.urlencode(params)
    return asc_json(url, token)


def next_build_number(visible_builds, marketing_version, now=None):
    # Use UTC so daylight-saving or local timezone changes cannot move backwards.
    timestamp = int((now or datetime.now(timezone.utc)).astimezone(timezone.utc).strftime("%y%m%d%H"))
    for version, number in visible_builds:
        if version != marketing_version:
            continue
        if not number.isdecimal():
            raise ReleaseError(f"Non-integer TestFlight build number {number!r}; refusing to guess")
        if int(number) >= timestamp:
            raise ReleaseError(
                f"UTC build {timestamp} is not greater than visible {marketing_version} ({number}); "
                "wait until a later UTC hour"
            )
    return timestamp


def lookup_build_number(token, marketing_version):
    apps = asc_get("apps", {"filter[bundleId]": APP_BUNDLE_ID,
                            "fields[apps]": "bundleId,name", "limit": 2}, token)
    if len(apps.get("data", [])) != 1:
        raise ReleaseError("Expected exactly one App Store Connect app for " + APP_BUNDLE_ID)
    app = apps["data"][0]
    app_id = app["id"]
    name = app.get("attributes", {}).get("name", ASC_APP_NAME)
    if name != ASC_APP_NAME:
        print(f"NOTE: App Store Connect app is named {name!r}, not {ASC_APP_NAME!r}")
    groups = asc_get("betaGroups", {"filter[app]": app_id, "limit": 100,
                                   "fields[betaGroups]": "name,isInternalGroup,hasAccessToAllBuilds"}, token)
    matching = [g for g in groups.get("data", []) if g["attributes"].get("name") == TESTFLIGHT_GROUP]
    if (len(matching) != 1 or not matching[0]["attributes"].get("isInternalGroup")
            or not matching[0]["attributes"].get("hasAccessToAllBuilds")):
        raise ReleaseError(f"Internal TestFlight group {TESTFLIGHT_GROUP!r} must exist and have access to all builds")
    builds = []
    url = None
    while True:
        params = {"filter[app]": app_id, "sort": "-uploadedDate", "limit": 200,
                  "fields[builds]": "version,preReleaseVersion", "include": "preReleaseVersion",
                  "fields[preReleaseVersions]": "version,platform"}
        if url is None:
            data = asc_get("builds", params, token)
        else:
            data = asc_json(url, token)
        versions = {v["id"]: v["attributes"]["version"] for v in data.get("included", [])
                    if v["type"] == "preReleaseVersions" and v["attributes"].get("platform") == "IOS"}
        for build in data.get("data", []):
            release = build.get("relationships", {}).get("preReleaseVersion", {}).get("data")
            if release and release["id"] in versions:
                builds.append((versions[release["id"]], build["attributes"]["version"]))
        url = data.get("links", {}).get("next")
        if not url:
            break
    number = next_build_number(builds, marketing_version)
    print(f"App Store Connect app: {name} ({APP_BUNDLE_ID})")
    print(f"TestFlight group {TESTFLIGHT_GROUP}: internal, automatically receives all builds")
    print(f"Selected {marketing_version} ({number}); "
          f"visible builds for this version: {[n for v, n in builds if v == marketing_version]}")
    return number


def profile_details(path):
    raw = subprocess.run(["security", "cms", "-D", "-i", str(path)], capture_output=True)
    if raw.returncode:
        raise ReleaseError("Cannot decode App Store provisioning profile")
    profile = plistlib.loads(raw.stdout)
    if (profile.get("Entitlements", {}).get("get-task-allow") is not False
            or "ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices")):
        raise ReleaseError("Profile is not an App Store distribution profile")
    team = profile["TeamIdentifier"][0]
    if profile["Entitlements"].get("application-identifier") != team + "." + APP_BUNDLE_ID:
        raise ReleaseError("Profile does not match " + APP_BUNDLE_ID)
    return profile, team


def read_json_config(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise ReleaseError(f"Cannot read {path}: {error}") from error


def release_config(path):
    if not path.is_file():
        raise ReleaseError(f"Missing {path}; copy Config/TestFlight.local.json.example and fill it in")
    if path.stat().st_mode & 0o077:
        raise ReleaseError(f"Restrict {path} to your user: chmod 600 {path}")
    config = read_json_config(path)
    fields = ("apiKeyId", "issuerId", "apiKeyPath", "distributionP12Path",
              "distributionP12PasswordFile", "appStoreProfilePath")
    if not isinstance(config, dict) or any(not isinstance(config.get(k), str) or not config[k] for k in fields):
        raise ReleaseError(f"Incomplete TestFlight config: {path}")
    for key in ("apiKeyPath", "distributionP12Path", "distributionP12PasswordFile", "appStoreProfilePath"):
        config[key] = Path(config[key]).expanduser().resolve()
        if ROOT in config[key].parents:
            raise ReleaseError(f"Signing file must be outside the repository: {config[key]}")
        if not config[key].is_file():
            raise ReleaseError(f"Missing signing file: {config[key]}")
        if key != "appStoreProfilePath" and config[key].stat().st_mode & 0o077:
            raise ReleaseError(f"Restrict signing file to your user: chmod 600 {config[key]}")
    config["p12Password"] = config["distributionP12PasswordFile"].read_text().rstrip("\r\n")
    if not config["p12Password"]:
        raise ReleaseError("Empty distribution .p12 password file")
    return config


def local_signing(profile_path, p12_path, p12_password, output_dir):
    """Yield (profile_name, team, signing_cert_hash); restore keychain/profile on exit."""
    from contextlib import contextmanager

    @contextmanager
    def setup():
        profile, team = profile_details(profile_path)
        keychain = output_dir / "signing.keychain-db"
        password = secrets.token_urlsafe(36)
        search_list = shlex.split(command(["security", "list-keychains", "-d", "user"]))
        profile_dest = (Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
                        / (profile["UUID"] + ".mobileprovision"))
        installed = False
        created = False
        try:
            command(["security", "create-keychain", "-p", password, str(keychain)])
            created = True
            command(["security", "unlock-keychain", "-p", password, str(keychain)])
            command(["security", "set-keychain-settings", "-lut", "21600", str(keychain)])
            command(["security", "import", str(p12_path), "-k", str(keychain), "-P", p12_password,
                     "-T", "/usr/bin/codesign"])
            command(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                     "-s", "-k", password, str(keychain)])
            identities = command(["security", "find-identity", "-v", "-p", "codesigning", str(keychain)])
            # keychain find-identity prints SHA-1 digests; this is identity
            # matching against the profile, not a security use of the hash.
            expected = {hashlib.new("sha1", bytes(cert), usedforsecurity=False).hexdigest().upper()
                        for cert in profile["DeveloperCertificates"]}
            matches = [m.group(1) for line in identities.splitlines()
                       if (m := re.search(r"\b([A-F0-9]{40})\b.*Apple Distribution:", line))
                       and m.group(1) in expected and f"({team})" in line]
            if len(matches) != 1:
                raise ReleaseError("Imported Apple Distribution identity does not match the profile")
            profile_dest.parent.mkdir(parents=True, exist_ok=True)
            if profile_dest.exists():
                if profile_dest.read_bytes() != profile_path.read_bytes():
                    raise ReleaseError("Another profile already uses this UUID")
            else:
                shutil.copyfile(profile_path, profile_dest)
                profile_dest.chmod(0o600)
                installed = True
            command(["security", "list-keychains", "-d", "user", "-s", str(keychain), *search_list])
            yield profile["Name"], team, matches[0]
        finally:
            if installed:
                try:
                    profile_dest.unlink(missing_ok=True)
                except OSError as error:
                    print("WARNING: could not remove temporary profile:", error, file=sys.stderr)
            try:
                command(["security", "list-keychains", "-d", "user", "-s", *search_list])
            except ReleaseError as error:
                print("WARNING: could not restore keychain search list:", error, file=sys.stderr)
            if created:
                try:
                    command(["security", "delete-keychain", str(keychain)])
                except ReleaseError as error:
                    print("WARNING: could not delete temporary keychain:", error, file=sys.stderr)
    return setup()


def verify_ipa(ipa, marketing_version, build_number, team):
    with zipfile.ZipFile(ipa) as archive:
        info_path = f"Payload/{APP_NAME}.app/Info.plist"
        try:
            info = plistlib.loads(archive.read(info_path))
        except KeyError:
            raise ReleaseError(f"IPA has no {info_path}; was {APP_NAME}.app archived?") from None
        if (info.get("CFBundleIdentifier") != APP_BUNDLE_ID
                or info.get("CFBundleShortVersionString") != marketing_version
                or info.get("CFBundleVersion") != str(build_number)
                or info.get("ITSAppUsesNonExemptEncryption") is not False):
            raise ReleaseError("Exported IPA has unexpected ID, version, build, or compliance declaration")
        with tempfile.TemporaryDirectory(prefix="mudi-ipa-check-") as temp:
            archive.extractall(temp)
            app = Path(temp) / f"Payload/{APP_NAME}.app"
            command(["codesign", "--verify", "--deep", "--strict", str(app)])
            signature = subprocess.run(["codesign", "-dvv", str(app)], capture_output=True, text=True)
            if (signature.returncode or "Authority=Apple Distribution:" not in signature.stderr
                    or f"TeamIdentifier={team}" not in signature.stderr):
                raise ReleaseError("IPA was not signed locally by the expected Apple Distribution team")
            embedded, embedded_team = profile_details(app / "embedded.mobileprovision")
            if embedded_team != team:
                raise ReleaseError("IPA embeds a profile from another team")
    print(f"IPA verified: {APP_BUNDLE_ID} {marketing_version} ({build_number}), "
          "Apple Distribution, export compliance declared")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upload", action="store_true", help="Upload after local signing and Apple validation")
    args = parser.parse_args()
    config = release_config(ROOT / "Config/TestFlight.local.json")
    if args.upload and command(["git", "status", "--porcelain", "--untracked-files=normal"]).strip():
        raise ReleaseError("Refusing to upload from a dirty worktree")
    marketing = app_build_settings()
    token = jwt(config["apiKeyId"], config["issuerId"], config["apiKeyPath"])
    number = lookup_build_number(token, marketing)
    output_dir = Path(tempfile.mkdtemp(prefix="mudi-testflight-")).resolve()
    print("Artifacts/logs:", output_dir)
    with local_signing(config["appStoreProfilePath"], config["distributionP12Path"],
                       config["p12Password"], output_dir) as (profile_name, team, cert_hash):
        archive = output_dir / f"{SCHEME}.xcarchive"
        signing = ["CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=" + cert_hash,
                   "PROVISIONING_PROFILE_SPECIFIER=" + profile_name, "DEVELOPMENT_TEAM=" + team,
                   "CURRENT_PROJECT_VERSION=" + str(number), "MARKETING_VERSION=" + marketing]
        command(["xcodebuild", "-project", PROJECT, "-scheme", SCHEME,
                 "-configuration", "Release", "-destination", "generic/platform=iOS",
                 "-derivedDataPath", str(output_dir / "DerivedData"), "-archivePath", str(archive),
                 *signing, "archive"], log=output_dir / "archive.log")
        options = {"method": "app-store-connect", "destination": "export", "signingStyle": "manual",
                   "signingCertificate": cert_hash, "teamID": team,
                   "provisioningProfiles": {APP_BUNDLE_ID: profile_name},
                   "manageAppVersionAndBuildNumber": False}
        opts_path = output_dir / "ExportOptions.plist"
        opts_path.write_bytes(plistlib.dumps(options))
        command(["xcodebuild", "-exportArchive", "-archivePath", str(archive),
                 "-exportPath", str(output_dir / "export"), "-exportOptionsPlist", str(opts_path)],
                log=output_dir / "export.log")
        ipa = output_dir / f"export/{APP_NAME}.ipa"
        if not ipa.is_file():
            raise ReleaseError(f"Xcode export finished without {APP_NAME}.ipa")
        verify_ipa(ipa, marketing, number, team)
    auth = ["--api-key", config["apiKeyId"], "--api-issuer", config["issuerId"],
            "--p8-file-path", str(config["apiKeyPath"])]
    command(["xcrun", "altool", "--validate-app", "-f", str(ipa), "-t", "ios", *auth],
            log=output_dir / "validate.log")
    print("Apple validation passed. IPA:", ipa)
    if args.upload:
        command(["xcrun", "altool", "--upload-app", "-f", str(ipa), "-t", "ios", *auth],
                log=output_dir / "upload.log")
        text = (output_dir / "upload.log").read_text(errors="replace")
        delivery = re.search(r"Delivery UUID:\s*([\w-]+)", text)
        print("Upload accepted; delivery ID:", delivery.group(1) if delivery else "see upload.log")
        print("Processing and TestFlight availability are asynchronous; check App Store Connect.")
    else:
        print("No upload requested. Pass --upload to publish a build.")


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, OSError, ValueError, KeyError, urllib.error.URLError) as error:
        print("ERROR:", error, file=sys.stderr)
        sys.exit(1)
