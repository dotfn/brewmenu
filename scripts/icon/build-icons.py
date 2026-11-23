#!/usr/bin/env python3
"""Builds every BrewMenu icon from the one source PSD.

    python3 scripts/icon/build-icons.py [path/to/BrewMenu-Icon-Source.psd]

The source is a flattened render: a rounded-rect body on an opaque black canvas. This script
finds the body, cuts it out with a fitted rounded-rect mask (anti-aliased, inset so no black
fringe survives), and writes:

  App   Sources/Resources/AppIcon.icns   macOS grid: body 824 of 1024, centred, soft shadow,
                                         every iconset size 16–1024 (@1x/@2x)
        brewmenu.png                     the 1024 master
  Web   web/public/favicon.ico/.svg, favicon-16x16.png, favicon-32x32.png   tight crop, no padding
        web/public/apple-touch-icon.png  180, opaque (iOS draws its own corners)
        web/public/icon-192.png, icon-512.png   web manifest
        web/public/app-icon-96.png       the notification mock on the site

Needs macOS (sips, iconutil) and Pillow + numpy.
"""

from __future__ import annotations

import base64
import io
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
SRC = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "design" / "BrewMenu-Icon-Source.psd"
PUBLIC = ROOT / "web" / "public"

# The body's corner, measured on the source: a rounded rect of radius 244 on the 1007px body fits
# its edge at 99.8% IoU (a superellipse fits worse). Expressed as a fraction of the body width.
CORNER = 244 / 1007
# The source has a faint glow (lum 5–9) and a black pixel just outside the body; the body edge is
# where luminance passes 20. Counting the glow made the mask 3px too big: a black ring on light.
EDGE = 20
INSET = 3  # px on the source: the edge pixel is half black, and the real corner is a touch rounder than the fit


def load(path: Path) -> Image.Image:
    with tempfile.TemporaryDirectory() as tmp:
        png = Path(tmp) / "src.png"
        subprocess.run(["sips", "-s", "format", "png", str(path), "--out", str(png)], check=True, capture_output=True)
        return Image.open(png).convert("RGB")


def body_box(img: Image.Image) -> tuple[int, int, int, int]:
    a = np.asarray(img).astype(float)
    lum = 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]
    ys, xs = np.where(lum > EDGE)
    return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1


def cut_out(img: Image.Image) -> Image.Image:
    """The body alone, on transparency, cropped square to its own bounds."""
    x0, y0, x1, y1 = body_box(img)
    side = max(x1 - x0, y1 - y0)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    box = (round(cx - side / 2), round(cy - side / 2), round(cx + side / 2), round(cy + side / 2))
    crop = img.crop(box).convert("RGBA")
    s = 4  # supersample the mask for a clean edge
    fitted = Image.new("L", (side * s, side * s), 0)
    r = CORNER * side * s
    i = round(INSET * s)
    ImageDraw.Draw(fitted).rounded_rectangle([i, i, side * s - i - 1, side * s - i - 1], radius=r - i, fill=255)
    fitted = fitted.resize((side, side), Image.LANCZOS)
    # The artwork's own silhouette, shrunk by the inset: where the drawn corner is rounder than the
    # fit, this wins, so no black from the canvas ever gets inside the mask.
    a = np.asarray(crop.convert("RGB")).astype(float)
    lum = 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]
    real = np.zeros(lum.shape, dtype=np.uint8)
    for y, row in enumerate(lum > EDGE):
        xs = np.where(row)[0]
        if len(xs):
            real[y, xs[0] : xs[-1] + 1] = 255
    for x, col in enumerate((real > 0).T):  # also bound each column, for the top and bottom curves
        ys = np.where(col)[0]
        if len(ys):
            real[: ys[0], x] = 0
            real[ys[-1] + 1 :, x] = 0
    k = 2 * round(INSET) + 1
    real_img = Image.fromarray(real).filter(ImageFilter.MinFilter(k)).filter(ImageFilter.GaussianBlur(0.7))
    crop.putalpha(Image.fromarray(np.minimum(np.asarray(fitted), np.asarray(real_img))))
    return crop


def resize(img: Image.Image, size: int) -> Image.Image:
    out = img.resize((size, size), Image.LANCZOS)
    if size <= 48:  # small sizes go soft; bring the edges back a little
        out = out.filter(ImageFilter.UnsharpMask(radius=0.6, percent=60, threshold=1))
    return out


def macos_master(body: Image.Image) -> Image.Image:
    """Apple's macOS grid: 1024 canvas, 824 body centred, a soft shadow from above."""
    canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    b = body.resize((824, 824), Image.LANCZOS)
    shadow = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    alpha = b.getchannel("A").point(lambda v: v * 0.32)
    shadow.paste((0, 0, 0, 255), (100, 112), alpha)
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(14)))
    canvas.alpha_composite(b, (100, 100))
    return canvas


def iconset(master: Image.Image, out_icns: Path) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp) / "AppIcon.iconset"
        d.mkdir()
        for pt in (16, 32, 128, 256, 512):
            resize(master, pt).save(d / f"icon_{pt}x{pt}.png")
            resize(master, pt * 2).save(d / f"icon_{pt}x{pt}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(d), "-o", str(out_icns)], check=True)


def touch_icon(body: Image.Image, size: int = 180) -> Image.Image:
    """iOS masks with its own (smaller) corner, so zoom past the body's corners and fill the rest
    with the body's own edge colour: no black wedges, nothing transparent."""
    side = body.width
    k = round(side * 0.043)  # trims the artwork's wider corners under iOS's ~22% radius
    inner = body.crop((k, k, side - k, side - k))
    edge = np.asarray(body.convert("RGB"))[side // 2, k + 6]
    bg = Image.new("RGBA", inner.size, (*map(int, edge), 255))
    return Image.alpha_composite(bg, inner).convert("RGB").resize((size, size), Image.LANCZOS)


def main() -> None:
    if not SRC.exists():
        sys.exit(f"source not found: {SRC}")
    img = load(SRC)
    body = cut_out(img)
    master = macos_master(body)

    iconset(master, ROOT / "Sources" / "Resources" / "AppIcon.icns")
    master.save(ROOT / "brewmenu.png")

    for s in (16, 32):
        resize(body, s).save(PUBLIC / f"favicon-{s}x{s}.png")
    resize(body, 48).save(PUBLIC / "favicon.ico", sizes=[(16, 16), (32, 32), (48, 48)])
    buf = io.BytesIO()
    resize(body, 128).save(buf, "PNG", optimize=True)
    (PUBLIC / "favicon.svg").write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">\n'
        f'  <image href="data:image/png;base64,{base64.b64encode(buf.getvalue()).decode()}" width="128" height="128"/>\n'
        "</svg>\n"
    )
    touch_icon(body).save(PUBLIC / "apple-touch-icon.png", optimize=True)
    for s in (192, 512):
        resize(body, s).save(PUBLIC / f"icon-{s}.png", optimize=True)
    resize(body, 96).save(PUBLIC / "app-icon-96.png", optimize=True)
    print("icons written from", SRC)


if __name__ == "__main__":
    if not shutil.which("iconutil"):
        sys.exit("iconutil not found: run on macOS")
    main()
