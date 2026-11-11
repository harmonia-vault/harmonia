"""在 GitHub Actions 中准备、清理 TestFlight 的临时签名材料。"""
import base64
import datetime
import json
import os
from pathlib import Path
import plistlib
import secrets
import subprocess
import sys
import uuid

BUNDLE = "org.harmoniavault.harmonia"
ROOT = Path(__file__).resolve().parents[1] / "ios"
PROFILE_DIRS = ["Library/MobileDevice/Provisioning Profiles",
                "Library/Developer/Xcode/UserData/Provisioning Profiles"]


def export_options(profile):
    team = profile["TeamIdentifier"][0]
    entitlements = profile["Entitlements"]
    if entitlements.get("application-identifier") != f"{team}.{BUNDLE}":
        raise ValueError("描述文件与 Harmonia 的应用标识不一致")
    if (profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices")
            or entitlements.get("get-task-allow") or not entitlements.get("beta-reports-active")):
        raise ValueError("请使用 App Store 分发描述文件")
    if entitlements.get("aps-environment") != "production":
        raise ValueError("请启用正式环境推送后重新生成描述文件")
    if profile["ExpirationDate"] <= datetime.datetime.now(datetime.UTC).replace(tzinfo=None):
        raise ValueError("描述文件已过期，请重新生成")
    return {"method": "app-store-connect", "teamID": team, "signingStyle": "manual",
            "signingCertificate": "Apple Distribution", "manageAppVersionAndBuildNumber": False,
            "testFlightInternalTestingOnly": True,
            "provisioningProfiles": {BUNDLE: str(uuid.UUID(profile["UUID"])).upper()}}


def security(*args):
    # 不让包含密码的命令参数进入异常或日志。
    result = subprocess.run(["security", *args], capture_output=True)
    if result.returncode:
        raise SystemExit(result.stderr.decode())
    return result.stdout


def main():
    directory = Path(os.environ["RUNNER_TEMP"]) / "harmonia-ios-signing"
    keychain = directory / "distribution.keychain-db"
    state = directory / "state.json"
    config = ROOT / "Flutter/Signing.xcconfig"
    if sys.argv[1] == "clean":
        if state.exists():
            saved = json.loads(state.read_text())
            security("list-keychains", "-d", "user", "-s", *saved["keychains"])
            for relative in PROFILE_DIRS:
                (Path.home() / relative / f'{saved["profile"]}.mobileprovision').unlink(missing_ok=True)
        if keychain.exists():
            security("delete-keychain", str(keychain))
        config.unlink(missing_ok=True)
        import shutil
        shutil.rmtree(directory, ignore_errors=True)
        return
    os.umask(0o077)
    directory.mkdir()
    certificate = directory / "distribution.p12"
    certificate.write_bytes(base64.b64decode(os.environ["IOS_CERTIFICATE_BASE64"], validate=True))
    source = directory / "app.mobileprovision"
    source.write_bytes(base64.b64decode(os.environ["IOS_APP_PROFILE_BASE64"], validate=True))
    profile = plistlib.loads(security("cms", "-D", "-i", str(source)))
    options = export_options(profile)
    identifier = options["provisioningProfiles"][BUNDLE]
    import shlex
    keychains = shlex.split(security("list-keychains", "-d", "user").decode())
    state.write_text(json.dumps({"keychains": keychains, "profile": identifier}))
    password = secrets.token_hex(32)
    security("create-keychain", "-p", password, str(keychain))
    security("set-keychain-settings", "-lut", "21600", str(keychain))
    security("unlock-keychain", "-p", password, str(keychain))
    security("import", str(certificate), "-k", str(keychain), "-P", os.environ["IOS_CERTIFICATE_PASSWORD"],
             "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
    security("set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, str(keychain))
    security("list-keychains", "-d", "user", "-s", str(keychain), *keychains)
    for relative in PROFILE_DIRS:
        destination = Path.home() / relative
        destination.mkdir(parents=True, exist_ok=True)
        (destination / f"{identifier}.mobileprovision").write_bytes(source.read_bytes())
    entitlements = plistlib.loads((ROOT / "Runner/Runner.entitlements").read_bytes())
    entitlements["aps-environment"] = "production"
    (directory / "Runner.entitlements").write_bytes(plistlib.dumps(entitlements))
    config.write_text(f"HARMONIA_ENTITLEMENTS = {directory / 'Runner.entitlements'}\n"
                      f"CODE_SIGN_STYLE = Manual\nDEVELOPMENT_TEAM = {options['teamID']}\n"
                      f"CODE_SIGN_IDENTITY = Apple Distribution\nPROVISIONING_PROFILE_SPECIFIER = {identifier}\n")
    (directory / "ExportOptions.plist").write_bytes(plistlib.dumps(options))


if __name__ == "__main__":
    main()
