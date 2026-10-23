#!/usr/bin/env python3
import argparse
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import zipfile


def verify(architecture, tag):
    root = Path(__file__).resolve().parent.parent
    source = plistlib.loads((root / "Resources/Info.plist").read_bytes())
    version = source["CFBundleShortVersionString"]
    build = source["CFBundleVersion"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not build.isdigit() or int(build) < 1:
        raise ValueError("Invalid app version or build number")
    if tag and tag != f"v{version}":
        raise ValueError(f"Tag {tag!r} does not match app version {version}")

    app = root / "build/Tailscale GPU Tracker.app"
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    if info != source:
        raise ValueError("Packaged Info.plist differs from the source")
    executable = app / "Contents/MacOS/TailscaleGPUTracker"
    actual_arch = subprocess.check_output(["/usr/bin/lipo", "-archs", str(executable)], text=True).strip()
    if actual_arch != architecture:
        raise ValueError(f"Expected architecture {architecture}, found {actual_arch}")

    binary = executable.read_bytes()
    private_paths = [rb"/Users/", rb"/home/", rb"/(?:private/)?var/folders/", rb"/(?:private/)?tmp/"]
    if any(re.search(pattern, binary) for pattern in private_paths) or str(root).encode() in binary:
        raise ValueError("Packaged executable contains local build paths")

    license_path = app / "Contents/Resources/LICENSE"
    if license_path.read_bytes() != (root / "LICENSE").read_bytes():
        raise ValueError("Packaged license is missing or differs from the source")
    icon_path = app / "Contents/Resources" / info["CFBundleIconFile"]
    icon = icon_path.read_bytes()
    if not icon.startswith(b"icns") or icon != (root / "Resources/AppIcon.icns").read_bytes():
        raise ValueError("Packaged icon is missing or differs from the source")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    signature = subprocess.run(["/usr/bin/codesign", "-dvv", str(app)], capture_output=True, text=True, check=True)
    if "Signature=adhoc" not in signature.stderr:
        raise ValueError("Expected a local ad-hoc signature")

    archive = root / f"build/Tailscale-GPU-Tracker-v{version}-macos-{architecture}.zip"
    with zipfile.ZipFile(archive) as package:
        if package.testzip() is not None:
            raise ValueError("Release ZIP is corrupt")
        for path in (executable, info_path, license_path, icon_path):
            member = path.relative_to(app.parent).as_posix()
            if package.read(member) != path.read_bytes():
                raise ValueError(f"Release ZIP has different content for {member}")
        member = package.getinfo(executable.relative_to(app.parent).as_posix())
        if not (member.external_attr >> 16) & 0o111:
            raise ValueError("Release ZIP does not preserve executable permissions")

    print(f"Verified {archive.name}: version {version}, build {build}, {architecture}, no local build paths.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--arch", required=True, choices=["arm64", "x86_64"])
    parser.add_argument("--tag", default="")
    args = parser.parse_args()
    try:
        verify(args.arch, args.tag)
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print(f"Release verification failed: {error}", file=sys.stderr)
        sys.exit(1)
