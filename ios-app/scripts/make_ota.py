#!/usr/bin/env python3
"""Prepare an over-the-air install page for a signed .ipa.

    python make_ota.py path/to/YTMusic-signed.ipa https://your-pc.your-tailnet.ts.net

Copies the IPA into backend/ota/, writes manifest.plist (reading the bundle id and version out of the IPA) and an
install page. Open  <server>/ota/  on the iPhone in Safari and tap "Install". The address must be HTTPS with a valid
certificate (your Tailscale address is), and the iPhone must be able to reach it (Tailscale connected).
"""
import plistlib, shutil, sys, zipfile
from pathlib import Path
from xml.sax.saxutils import escape

if len(sys.argv) != 3:
    sys.exit(__doc__)
ipa, server = Path(sys.argv[1]), sys.argv[2].rstrip("/")
if not server.startswith("https://"):
    sys.exit("The server address must start with https:// (iOS only installs apps over HTTPS).")
out = Path(__file__).resolve().parent.parent.parent / "backend" / "ota"
out.mkdir(parents=True, exist_ok=True)

with zipfile.ZipFile(ipa) as z:
    plist_name = next(n for n in z.namelist() if n.startswith("Payload/") and n.endswith(".app/Info.plist") and n.count("/") == 2)
    info = plistlib.loads(z.read(plist_name))
bundle, version, title = info["CFBundleIdentifier"], info.get("CFBundleShortVersionString", "1.0"), info.get("CFBundleDisplayName") or info.get("CFBundleName", "App")

target = out / "YTMusic.ipa"
shutil.copyfile(ipa, target)
manifest = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
  <key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>{escape(server)}/ota/YTMusic.ipa</string></dict></array>
  <key>metadata</key><dict><key>bundle-identifier</key><string>{escape(bundle)}</string><key>bundle-version</key><string>{escape(version)}</string><key>kind</key><string>software</string><key>title</key><string>{escape(title)}</string></dict>
</dict></array></dict></plist>
"""
(out / "manifest.plist").write_text(manifest, encoding="utf-8")
link = f"itms-services://?action=download-manifest&amp;url={server}/ota/manifest.plist"
(out / "index.html").write_text(f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Install {escape(title)}</title><style>body{{font:17px -apple-system,system-ui,sans-serif;background:#0c0c0f;color:#f4f2ee;margin:0;display:grid;place-items:center;min-height:100vh;text-align:center;padding:24px}}
a.btn{{display:inline-block;margin-top:20px;padding:14px 32px;border-radius:99px;background:#ff6a3d;color:#1a0a05;font-weight:700;text-decoration:none}}p{{color:#a3a1ab;max-width:320px;line-height:1.5}}</style></head>
<body><div><h1>{escape(title)}</h1><p>Version {escape(version)} · {escape(bundle)}</p><a class="btn" href="{link}">Install</a>
<p>First time? After installing, open <b>Settings → General → VPN &amp; Device Management</b> and trust the developer certificate, then open the app.</p></div></body></html>
""", encoding="utf-8")
print(f"bundle id : {bundle}\nversion   : {version}\nwrote     : {target}, manifest.plist, index.html\ninstall at: {server}/ota/")
