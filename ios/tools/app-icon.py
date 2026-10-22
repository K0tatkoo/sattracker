#!/usr/bin/env python3
"""Orbit's iPhone app icon, from the same mark as every other icon.

    python3 ios/tools/app-icon.py        (needs shapely, as tools/launcher-icon.py)

The mark ("ringed planet") is drawn by tools/launcher-icon.py, which this
imports rather than copies — one drawing, every platform. It writes three
1024 x 1024 SVGs and renders them to PNG with headless Chrome:

  AppIcon.png         the violet plate with the white mark (the Android icon)
  AppIcon-dark.png    for iOS's dark icons: the mark in the app's light violet
                      on the dark well colour
  AppIcon-tinted.png  for tinted icons: white on black; iOS tints it

The mark is 14/24 of the plate across, the Android launcher's proportion.
"""
import importlib.util
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "ios", "Orbit", "Assets.xcassets", "AppIcon.appiconset")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

spec = importlib.util.spec_from_file_location("launcher_icon", os.path.join(ROOT, "tools", "launcher-icon.py"))
icon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(icon)

SIZE = 1024
SCALE = 14 / 24 * SIZE / (icon.INK[2] - icon.INK[0])

VARIANTS = {
    "AppIcon.png": ("#6A45FF", "#FFFFFF"),
    "AppIcon-dark.png": ("#1B1E24", "#9B7CFF"),
    "AppIcon-tinted.png": ("#000000", "#FFFFFF"),
}


def svg(plate, ink):
    # The mark's ink centred on the plate (its grid centre is not the ink's:
    # the bead makes the right side a little heavier).
    cx = (icon.INK[0] + icon.INK[2]) / 2
    cy = (icon.INK[1] + icon.INK[3]) / 2
    d = icon.path_data(SIZE / 2 + (12 - cx) * SCALE, SIZE / 2 + (12 - cy) * SCALE, SCALE)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}">'
        f'<rect width="{SIZE}" height="{SIZE}" fill="{plate}"/>'
        f'<path d="{d}" fill="{ink}" fill-rule="evenodd"/></svg>'
    )


def main():
    os.makedirs(OUT, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for name, (plate, ink) in VARIANTS.items():
            page = os.path.join(tmp, name + ".html")
            with open(page, "w") as f:
                f.write(f"<!doctype html><html><body style='margin:0'>{svg(plate, ink)}</body></html>")
            shot = os.path.join(tmp, name)
            subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                            f"--window-size={SIZE},{SIZE}", f"--screenshot={shot}", "file://" + page],
                           check=True, capture_output=True)
            # App icons must be opaque: a round trip through BMP drops the alpha channel.
            bmp = shot + ".bmp"
            subprocess.run(["sips", "-s", "format", "bmp", shot, "--out", bmp], check=True, capture_output=True)
            subprocess.run(["sips", "-s", "format", "png", bmp, "--out", os.path.join(OUT, name)], check=True, capture_output=True)
            print("wrote", os.path.relpath(os.path.join(OUT, name), ROOT))


if __name__ == "__main__":
    sys.exit(main())
