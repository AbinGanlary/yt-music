"""Renders the mockup screens in docs/mockups to PNG files in docs/screenshots, using a headless Edge or Chrome.

    python docs/mockups/render.py            # all screens
    python docs/mockups/render.py home now   # just these
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "screenshots"
SCREENS = ["home", "now", "lyrics", "explore", "mix", "library", "analytics", "settings"]
BROWSERS = [
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    "/usr/bin/chromium", "/usr/bin/google-chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
]
browser = next((b for b in BROWSERS if os.path.exists(b)), None)
if not browser:
    sys.exit("No Edge or Chrome found")

tmp = Path(tempfile.mkdtemp())
for name in (sys.argv[1:] or SCREENS):
    raw = tmp / f"{name}.png"
    subprocess.run([
        browser, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=2",
        "--window-size=417,876", "--default-background-color=00000000", "--virtual-time-budget=3000",
        f"--screenshot={raw}", (HERE / "index.html").as_uri() + "#" + name,
    ], check=False, capture_output=True)
    im = Image.open(raw).convert("RGBA")
    im = im.resize((520, round(im.height * 520 / im.width)), Image.LANCZOS)
    dest = OUT / f"app-{name}.png"
    im.quantize(colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.FLOYDSTEINBERG).save(dest, optimize=True)
    print(dest.name, im.size, dest.stat().st_size // 1024, "KB")
