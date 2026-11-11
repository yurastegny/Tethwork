#!/usr/bin/env python3
"""Package an already Developer ID signed, notarized and stapled application.

Private Sparkle signing keys stay in the login Keychain. This script never
publishes assets or changes the live appcast; upload the ZIP first, then copy
the generated, signed appcast to updates/appcast.xml without editing it.
"""

import argparse
import base64
import hashlib
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET


def run(*args):
    return subprocess.run([str(arg) for arg in args], check=True, capture_output=True, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Notarized and stapled Tethwork.app exported by Xcode")
    parser.add_argument("--sparkle-bin", required=True, type=Path, help="Sparkle's bin directory from SourcePackages/artifacts")
    parser.add_argument("--account", default="app.tethwork.Tethwork", help="Sparkle signing account in Keychain")
    parser.add_argument("--notes", type=Path, help="Optional Markdown release notes to embed in the signed feed")
    parser.add_argument("--output", type=Path, help="New output directory (must not already exist)")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    app = args.app.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if app.name != "Tethwork.app" or info.get("CFBundleIdentifier") != "app.tethwork.Tethwork":
        parser.error("Expected the exported Tethwork.app")
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    channel = info.get("TethworkReleaseChannel", "")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"[1-9]\d*", build):
        parser.error("Expected a three-part version and an increasing integer build number")
    if channel not in ("", "stable", "beta"):
        parser.error("Unsupported release channel")
    tag = f"v{version}-beta.{build}" if channel == "beta" else f"v{version}"
    output = (args.output or repo / "build/releases" / tag).resolve()
    if output.exists():
        parser.error("Output directory already exists; refusing to overwrite a published archive")
    for tool in ("generate_keys", "generate_appcast", "sign_update"):
        if not (args.sparkle_bin / tool).is_file():
            parser.error(f"Missing Sparkle tool: {tool}")
    run("codesign", "--verify", "--deep", "--strict", app)
    signature = run("codesign", "-d", "--verbose=4", app).stderr
    if "Authority=Developer ID Application:" not in signature or "runtime" not in signature:
        parser.error("The app must be Developer ID signed with Hardened Runtime")
    architectures = set(run("lipo", "-archs", app / "Contents/MacOS" / info["CFBundleExecutable"]).stdout.split())
    if not {"arm64", "x86_64"}.issubset(architectures):
        parser.error("Expected a universal Apple Silicon + Intel application")
    # Refuse to publish a merely ad-hoc/development signed or unnotarized build.
    run("xcrun", "stapler", "validate", app)
    run("spctl", "--assess", "--type", "execute", "--verbose=2", app)
    public_key = run(args.sparkle_bin / "generate_keys", "--account", args.account, "-p").stdout.strip()
    if public_key != info.get("SUPublicEDKey") or len(base64.b64decode(public_key, validate=True)) != 32:
        parser.error("The Keychain signing key does not match the public key embedded in the app")
    expected_feed = "https://raw.githubusercontent.com/yurastegny/Tethwork/main/updates/appcast.xml"
    if info.get("SUFeedURL") != expected_feed or info.get("SURequireSignedFeed") is not True:
        parser.error("Unexpected feed URL or unsigned feed configuration")
    output.mkdir(parents=True)
    archive = output / f"Tethwork-{tag.removeprefix('v')}.zip"
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
    notes = output / (archive.stem + ".md")
    if args.notes:
        notes.write_bytes(args.notes.read_bytes())
    else:
        notes.write_text(f"## Tethwork {version} {'beta ' if channel == 'beta' else ''}(build {build})\n\n"
                         "- Signed and notarized universal macOS application.\n"
                         "- Sparkle update checks in the application and menu-bar menus.\n"
                         "- Update installation waits for active synchronization to finish.\n\n"
                         "Beta software: use at your own risk and keep independent backups.\n")
    feed = output / "appcast.xml"
    current_feed = repo / "updates/appcast.xml"
    if current_feed.is_file():
        shutil.copy2(current_feed, feed)
    command = [args.sparkle_bin / "generate_appcast", "--account", args.account,
               "--download-url-prefix", f"https://github.com/yurastegny/Tethwork/releases/download/{tag}/",
               "--full-release-notes-url", "https://github.com/yurastegny/Tethwork/releases",
               "--link", "https://github.com/yurastegny/Tethwork", "--embed-release-notes",
               "--versions", build, "--maximum-deltas", "0", "--maximum-versions", "0"]
    if channel == "beta":
        command += ["--channel", "beta"]
    run(*command, output)
    run(args.sparkle_bin / "sign_update", "--account", args.account, "--verify", feed)
    namespace = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
    items = ET.parse(feed).getroot().findall("./channel/item")
    item = next(item for item in items if item.findtext("sparkle:version", namespaces=namespace) == build)
    enclosure = item.find("enclosure")
    if enclosure is None:
        parser.error("Generated appcast is missing the release enclosure")
    expected_url = f"https://github.com/yurastegny/Tethwork/releases/download/{tag}/{archive.name}"
    if enclosure.get("url") != expected_url or int(enclosure.get("length", "0")) != archive.stat().st_size:
        parser.error("Generated download URL or archive size does not match the release")
    ed_signature = enclosure.get("{" + namespace["sparkle"] + "}edSignature")
    if not ed_signature:
        parser.error("Missing archive signature")
    run(args.sparkle_bin / "sign_update", "--account", args.account, "--verify", archive, ed_signature)
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / "SHA256SUMS").write_text(f"{checksum}  {archive.name}\n")
    print(f"Verified release {tag}: {output}")
    print("Upload the ZIP and SHA256SUMS to GitHub Releases first.")
    print(f"Then copy {feed} to updates/appcast.xml, commit and push without editing the signed XML.")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        print(f"Release verification failed: {error.cmd}", file=sys.stderr)
        print((error.stdout or "") + (error.stderr or ""), file=sys.stderr)
        sys.exit(error.returncode or 1)
