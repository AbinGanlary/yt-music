#!/usr/bin/env python3
"""Tweaks the generated Capacitor iOS project (run after `npx cap add ios` and `npx cap sync ios`).

 - Info.plist: display name, background audio, portrait only, no export-compliance prompt
 - AppDelegate.swift: audio session = playback, so music keeps playing with the screen locked
 - icon + dark launch screen, so the app doesn't flash white

Everything is idempotent and prints what it changed.
"""
import json, os, plistlib, re, struct, sys, zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "ios" / "App" / "App"
NAME = os.environ.get("APP_NAME", "YT Music")


def png_solid(path: Path, rgb=(12, 12, 15), size=8):
    raw = b"".join(b"\x00" + bytes(rgb) * size for _ in range(size))
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def patch_plist():
    p = APP / "Info.plist"
    d = plistlib.loads(p.read_bytes())
    d["CFBundleDisplayName"] = NAME
    d["UIBackgroundModes"] = ["audio"]
    d["UISupportedInterfaceOrientations"] = ["UIInterfaceOrientationPortrait"]
    d["UISupportedInterfaceOrientations~ipad"] = ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]
    d["ITSAppUsesNonExemptEncryption"] = False
    d["UIStatusBarStyle"] = "UIStatusBarStyleLightContent"
    p.write_bytes(plistlib.dumps(d))
    print(f"Info.plist: name={NAME!r}, UIBackgroundModes={d['UIBackgroundModes']}")


def patch_appdelegate():
    p = APP / "AppDelegate.swift"
    s = p.read_text(encoding="utf-8")
    if "AVAudioSession" in s:
        print("AppDelegate.swift: already patched"); return
    if "import AVFoundation" not in s:
        s = s.replace("import UIKit", "import UIKit\nimport AVFoundation", 1)
    snippet = (
        "        // Keep audio playing in the background and on the lock screen.\n"
        "        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])\n"
        "        try? AVAudioSession.sharedInstance().setActive(true)\n"
    )
    # insert before the first `return true` that follows didFinishLaunchingWithOptions
    m = re.search(r"didFinishLaunchingWithOptions[\s\S]*?\n(\s*)return true", s)
    if not m:
        sys.exit("AppDelegate.swift: couldn't find didFinishLaunchingWithOptions … return true")
    idx = m.start(1)
    s = s[:idx] + snippet + s[idx:]
    p.write_text(s, encoding="utf-8")
    print("AppDelegate.swift: audio session set to .playback")


def patch_native_http():
    """Adds the IPv4-only HTTPS client (native/Ipv4Http.swift) to AppDelegate.swift and registers it for the bridge."""
    p = APP / "AppDelegate.swift"
    s = p.read_text(encoding="utf-8")
    if "Ipv4HttpPlugin" in s:
        print("AppDelegate.swift: Ipv4Http already added")
    else:
        for mod in ("Foundation", "Network", "Security"):
            if f"import {mod}" not in s:
                s = s.replace("import UIKit", f"import UIKit\nimport {mod}", 1)
        if "import Capacitor" not in s:
            s = s.replace("import UIKit", "import UIKit\nimport Capacitor", 1)
        s = s.rstrip() + "\n\n" + (ROOT / "native" / "Ipv4Http.swift").read_text(encoding="utf-8")
        p.write_text(s, encoding="utf-8")
        print("AppDelegate.swift: added Ipv4HttpPlugin")
    cfg = APP / "capacitor.config.json"
    c = json.loads(cfg.read_text(encoding="utf-8"))
    lst = c.setdefault("packageClassList", [])
    if "Ipv4HttpPlugin" not in lst:
        lst.append("Ipv4HttpPlugin")
        cfg.write_text(json.dumps(c, indent=2), encoding="utf-8")
    print(f"capacitor.config.json: packageClassList={c['packageClassList']}")


def patch_icon_and_splash():
    assets = APP / "Assets.xcassets"
    icon = ROOT / "resources" / "icon-1024.png"
    sets = list((assets / "AppIcon.appiconset").glob("Contents.json"))
    if icon.exists() and sets:
        contents = json.loads(sets[0].read_text())
        names = {i["filename"] for i in contents.get("images", []) if "filename" in i}
        for n in names:
            (sets[0].parent / n).write_bytes(icon.read_bytes())
        print(f"icon: wrote {sorted(names)}")
    else:
        print("icon: skipped (no resources/icon-1024.png or no AppIcon.appiconset)")
    splash = assets / "Splash.imageset"
    if splash.exists():
        for f in splash.glob("*.png"):
            png_solid(f)
        print("splash: set to solid #0c0c0f")


if __name__ == "__main__":
    if not APP.exists():
        sys.exit(f"{APP} not found. Run `npx cap add ios` first.")
    patch_plist(); patch_appdelegate(); patch_native_http(); patch_icon_and_splash()
