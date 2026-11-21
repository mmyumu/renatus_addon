# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow", "numpy"]
# ///
"""Draws the icons of the two Windows apps: the crowned R of Renatus (the one on the back of
the album cards, tools/make_media.py) on an enamel tile with a gold rim.

- launcher (members): red enamel;
- admin (officers): night-blue enamel and a gold key in the corner (the key is also the
  admin icon in game, Renatus_Admin).

Run with:  uv run tools/make_app_icons.py [--preview DIR]
"""
import argparse
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 1024  # drawn large, then downscaled for clean edges

APPS = {
    "launcher": {"dark": (70, 6, 6), "light": (176, 30, 22), "key": False},
    "admin": {"dark": (8, 18, 48), "light": (40, 78, 150), "key": True},
}


def lerp(a, b, t):
    a, b = np.asarray(a, np.float64), np.asarray(b, np.float64)
    t = np.asarray(t, np.float64)[..., None]
    return a + (b - a) * t


def serif(px):
    for d in ["/usr/share/fonts/truetype/liberation", "/usr/share/fonts/truetype/dejavu"]:
        for n in ["LiberationSerif-Bold.ttf", "DejaVuSerif-Bold.ttf"]:
            try:
                return ImageFont.truetype(os.path.join(d, n), px)
            except OSError:
                pass
    raise SystemExit("No serif font found (fonts-liberation or fonts-dejavu).")


def rounded(box, radius, size=S):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return np.asarray(m).astype(np.float64) / 255


def gold_shade(mask_img, y, top, bottom):
    """Bevelled gold for a shape given as an L mask: lit from the top left."""
    blur = np.asarray(mask_img.filter(ImageFilter.GaussianBlur(6))).astype(np.float64) / 255
    gy, gx = np.gradient(blur)
    bevel = np.clip(0.55 + (-(gx + gy)) * 40, 0, 1)
    vert = np.clip((y - top) / max(1, bottom - top), 0, 1)
    col = lerp((255, 234, 165), (165, 108, 34), vert * 0.85)
    return col * (0.55 + 0.75 * bevel[..., None])


def paint(arr, mask, col):
    arr[..., :3] = arr[..., :3] * (1 - mask[..., None]) + col * mask[..., None]
    arr[..., 3] = np.maximum(arr[..., 3], mask * 255)


def shadow_under(arr, mask_img, dx, dy, blur, alpha):
    sh = mask_img.filter(ImageFilter.GaussianBlur(blur))
    sh = np.roll(np.roll(np.asarray(sh).astype(np.float64) / 255, dy, 0), dx, 1) * alpha
    arr[..., :3] = arr[..., :3] * (1 - sh[..., None]) + np.array((20, 4, 2)) * sh[..., None]


def draw(app):
    cfg = APPS[app]
    y, x = np.mgrid[0:S, 0:S].astype(np.float64) + 0.5
    arr = np.zeros((S, S, 4))
    # gold rim (bevelled), then the enamel tile inside it
    outer = (24, 24, S - 24, S - 24)
    rim = rounded(outer, 190)
    light = np.clip(0.5 - 0.5 * ((x - S / 2) + (y - S / 2)) / (S / 2), 0, 1)
    paint(arr, rim, lerp((112, 72, 24), (255, 222, 140), light))
    inner = rounded((70, 70, S - 70, S - 70), 150)
    glow = np.clip(1 - np.hypot(x - S * 0.36, y - S * 0.32) / (S * 0.85), 0, 1)
    paint(arr, inner, lerp(cfg["dark"], cfg["light"], glow))
    groove = rounded((86, 86, S - 86, S - 86), 136) - rounded((96, 96, S - 96, S - 96), 128)
    paint(arr, np.clip(groove, 0, 1), np.array((214, 160, 70)))

    # the crowned R, as a mask
    mask = Image.new("L", (S, S), 0)
    md = ImageDraw.Draw(mask)
    font = serif(int(S * 0.62))
    cx, cy = S / 2, S * 0.56
    bb = md.textbbox((0, 0), "R", font=font)
    tw, th = bb[2] - bb[0], bb[3] - bb[1]
    md.text((cx - tw / 2 - bb[0], cy - th / 2 - bb[1]), "R", font=font, fill=255)
    top_r = cy - th / 2
    cw, cb_, ct = S * 0.17, top_r - S * 0.035, top_r - S * 0.165
    md.polygon([(cx - cw, cb_), (cx - cw, ct + S * 0.03), (cx - cw * 0.5, cb_ - S * 0.05), (cx, ct),
                (cx + cw * 0.5, cb_ - S * 0.05), (cx + cw, ct + S * 0.03), (cx + cw, cb_)], fill=255)
    for px, py in ((cx - cw, ct + S * 0.03), (cx, ct), (cx + cw, ct + S * 0.03)):
        pr = S * 0.028
        md.ellipse([px - pr, py - pr, px + pr, py + pr], fill=255)
    shadow_under(arr, mask.filter(ImageFilter.MaxFilter(9)), 10, 14, 10, 0.85)
    m = np.asarray(mask).astype(np.float64) / 255
    paint(arr, m, gold_shade(mask, y, ct, cy + th / 2))

    if cfg["key"]:
        # gold key on a dark round badge, bottom right
        bx, by, br = S * 0.76, S * 0.76, S * 0.19
        badge = Image.new("L", (S, S), 0)
        ImageDraw.Draw(badge).ellipse([bx - br, by - br, bx + br, by + br], fill=255)
        shadow_under(arr, badge, 8, 12, 14, 0.8)
        bm = np.asarray(badge).astype(np.float64) / 255
        paint(arr, bm, lerp((112, 72, 24), (255, 222, 140), light))
        ib = Image.new("L", (S, S), 0)
        ImageDraw.Draw(ib).ellipse([bx - br + 16, by - br + 16, bx + br - 16, by + br - 16], fill=255)
        paint(arr, np.asarray(ib).astype(np.float64) / 255, lerp((14, 10, 8), (52, 36, 22), glow))
        key = Image.new("L", (S, S), 0)
        kd = ImageDraw.Draw(key)
        # bow (ring), shaft and two teeth, drawn diagonally
        rx, ry, rr = bx - br * 0.38, by - br * 0.38, br * 0.30
        kd.ellipse([rx - rr, ry - rr, rx + rr, ry + rr], fill=255)
        kd.ellipse([rx - rr * 0.45, ry - rr * 0.45, rx + rr * 0.45, ry + rr * 0.45], fill=0)
        ex, ey = bx + br * 0.52, by + br * 0.52
        kd.line([(rx + rr * 0.6, ry + rr * 0.6), (ex, ey)], fill=255, width=int(br * 0.17))
        for f in (0.62, 0.86):
            tx, ty = rx + (ex - rx) * f, ry + (ey - ry) * f
            kd.line([(tx, ty), (tx + br * 0.20, ty - br * 0.20)], fill=255, width=int(br * 0.15))
        km = np.asarray(key).astype(np.float64) / 255
        paint(arr, km, gold_shade(key, y, by - br, by + br))

    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGBA")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", help="also write PNG previews (with small sizes) to this directory")
    args = ap.parse_args()
    for app in APPS:
        out = os.path.join(ROOT, app, "src-tauri", "icons")
        os.makedirs(out, exist_ok=True)
        big = draw(app)
        big.resize((512, 512), Image.LANCZOS).save(os.path.join(out, "icon.png"))
        big.save(os.path.join(out, "icon.ico"),
                 sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
        print("icons ->", out)
        if args.preview:
            os.makedirs(args.preview, exist_ok=True)
            sheet = Image.new("RGBA", (256 + 128 + 48 + 32 + 16 + 60, 256), (43, 31, 21, 255))
            px = 0
            for sz in (256, 128, 48, 32, 16):
                sheet.alpha_composite(big.resize((sz, sz), Image.LANCZOS), (px, 0))
                px += sz + 12
            sheet.save(os.path.join(args.preview, f"{app}.png"))


if __name__ == "__main__":
    main()
