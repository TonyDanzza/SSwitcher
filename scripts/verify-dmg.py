"""Inspect the mounted, read-only release without installing or launching it."""
import plistlib
from pathlib import Path
import subprocess
import sys

from ds_store import DSStore

image = Path(sys.argv[1]).resolve()
result = subprocess.check_output([
    "hdiutil", "attach", "-readonly", "-nobrowse", "-plist", str(image)
])
entities = plistlib.loads(result)["system-entities"]
volume = Path(next(item["mount-point"] for item in entities if "mount-point" in item))
try:
    visible = {item.name for item in volume.iterdir() if not item.name.startswith(".")}
    assert visible == {"SSwitcher.app", "Applications"}, visible
    assert (volume / "Applications").is_symlink()
    assert (volume / "Applications").readlink() == Path("/Applications")
    app = volume / "SSwitcher.app"
    with (app / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    with Path("Resources/Info.plist").open("rb") as file:
        expected = plistlib.load(file)
    for key in ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion"]:
        assert info[key] == expected[key], key
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    architectures = subprocess.check_output([
        "lipo", "-archs", str(app / "Contents/MacOS/SSwitcher")
    ], text=True).split()
    assert set(architectures) == {"arm64", "x86_64"}, architectures
    with DSStore.open(str(volume / ".DS_Store"), "r") as store:
        assert store["SSwitcher.app"]["Iloc"] == (170, 190)
        assert store["Applications"]["Iloc"] == (470, 190)
        assert store["."]["icvp"]["iconSize"] == 100
    print(f"Verified {image.name}: signed universal app, Applications link, version and Finder layout.")
finally:
    subprocess.run(["hdiutil", "detach", str(volume)], check=True)
