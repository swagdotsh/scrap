#!/usr/bin/env python3
import argparse
import hashlib
import plistlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ACCOUNT = "com.swagrelated.scrap"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def run(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True).strip()


def version_parts(value):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value):
        raise ValueError("Use a numeric release version, for example 1.4 or 1.4.1.")
    parts = [int(part) for part in value.split(".")]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def main():
    parser = argparse.ArgumentParser(description="Package a built macOS app and prepare (never publish) a signed Sparkle feed.")
    parser.add_argument("--app", type=Path, required=True, help="Built universal Release .app")
    parser.add_argument("--sparkle-tools", type=Path, required=True, help="Sparkle artifact bin directory")
    parser.add_argument("--notes", type=Path, help="Optional plain-text release notes")
    args = parser.parse_args()
    app = args.app.resolve()
    tools = args.sparkle_tools.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    version_parts(version)
    if build != version:
        raise ValueError("Set CURRENT_PROJECT_VERSION and MARKETING_VERSION to the same release version.")
    config = plistlib.loads((ROOT / "Config/Info.plist").read_bytes())
    for key, value in config.items():
        if info.get(key) != value:
            raise ValueError(f"The built app's {key} does not match Config/Info.plist. Rebuild first.")
    if info["CFBundleIdentifier"] != ACCOUNT:
        raise ValueError("This is not a Scrap release bundle.")
    public_key = run(tools / "generate_keys", "--account", ACCOUNT, "-p")
    if public_key != info["SUPublicEDKey"]:
        raise ValueError("The signing key in Keychain does not match the app's public key.")
    architectures = run("lipo", "-archs", app / "Contents/MacOS" / info["CFBundleExecutable"]).split()
    if not {"arm64", "x86_64"}.issubset(architectures):
        raise ValueError("Build both arm64 and x86_64 before preparing a universal release.")
    run("codesign", "--verify", "--deep", "--strict", app)
    feed = ROOT / "appcast.xml"
    if feed.exists():
        for item in ET.parse(feed).findall("./channel/item"):
            old = item.findtext(f"{{{SPARKLE}}}version")
            if old and version_parts(old) >= version_parts(build):
                raise ValueError(f"The feed already contains build {old}. Use a newer release version.")
    output = ROOT / "Releases" / version
    if output.exists():
        raise ValueError(f"{output} already exists; refusing to overwrite a prepared release.")
    output.parent.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="scrap-update-", dir=output.parent) as temporary:
        staging = Path(temporary)
        archive = staging / f"scrap-v{version}-universal.zip"
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
        if feed.exists():
            shutil.copy2(feed, staging / "appcast.xml")
        if args.notes:
            shutil.copy2(args.notes, archive.with_suffix(".txt"))
        run(tools / "generate_appcast", "--account", ACCOUNT,
            "--download-url-prefix", f"https://github.com/swagdotsh/scrap/releases/download/v{version}/",
            "--link", f"https://github.com/swagdotsh/scrap/releases/tag/v{version}",
            "--embed-release-notes", "--maximum-deltas", "0", staging)
        candidate = staging / "appcast.xml"
        entries = ET.parse(candidate).findall("./channel/item")
        entry = next(item for item in entries if item.findtext(f"{{{SPARKLE}}}version") == build)
        enclosure = entry.find("enclosure")
        signature = enclosure.attrib[f"{{{SPARKLE}}}edSignature"]
        if int(enclosure.attrib["length"]) != archive.stat().st_size:
            raise ValueError("The feed's archive size is incorrect.")
        run(tools / "sign_update", "--account", ACCOUNT, "--verify", archive, signature)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        archive.with_suffix(".zip.sha256").write_text(f"{digest}  {archive.name}\n")
        output.mkdir()
        for path in staging.iterdir():
            if path.is_file():
                shutil.copy2(path, output / path.name)
    print(f"Prepared and verified: {output}")
    print("Upload the ZIP and checksum to the matching GitHub release first.")
    print("Then copy the prepared appcast.xml to the repository root and publish it on main.")
    print("No files have been uploaded and the live feed has not been changed.")


if __name__ == "__main__":
    main()
