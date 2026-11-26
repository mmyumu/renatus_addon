# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow", "numpy"]
# ///
"""Draws the avatar of the gazette's Discord webhook: the in-game gazette icon
(tools/make_media.py, gazette_icon) on a red enamel disc with a gold rim, the colours of
the launcher icon. Discord crops avatars to a circle, so everything stays inside it.

Run with:  uv run tools/make_discord_avatar.py [OUT.png]
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_media import gazette_icon  # noqa: E402

SIZE = 512
S = 2  # drawn twice as large, then reduced


def disc(w):
    """Red enamel disc (radial gradient) with a double gold rim."""
    yy, xx = np.mgrid[0:w, 0:w].astype(np.float64)
    c = (w - 1) / 2
    r = np.sqrt((xx - c) ** 2 + (yy - c) ** 2) / c  # 0 centre, 1 edge
    dark, light = np.array([70, 6, 6.0]), np.array([176, 30, 22.0])
    t = np.clip(1 - r * 0.9 - (yy - c) / c * 0.15, 0, 1)[..., None]
    rgb = dark + (light - dark) * t
    img = np.zeros((w, w, 4))
    img[..., :3] = rgb
    img[..., 3] = 255
    im = Image.fromarray(img.astype(np.uint8), "RGBA")
    d = ImageDraw.Draw(im)
    gold, deep = (214, 170, 72, 255), (120, 84, 24, 255)
    m = w * 0.02
    d.ellipse([m, m, w - m, w - m], outline=deep, width=int(w * 0.035))
    d.ellipse([m + w * 0.008, m + w * 0.008, w - m - w * 0.008, w - m - w * 0.008], outline=gold, width=int(w * 0.02))
    m2 = w * 0.075
    d.ellipse([m2, m2, w - m2, w - m2], outline=gold, width=max(2, int(w * 0.006)))
    # round mask so the corners stay transparent
    mask = Image.new("L", (w, w), 0)
    ImageDraw.Draw(mask).ellipse([m * 0.5, m * 0.5, w - m * 0.5, w - m * 0.5], fill=255)
    im.putalpha(mask)
    return im


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "discord_avatar.png")
    W = SIZE * S
    base = disc(W)
    icon_w = int(W * 0.70)
    icon = Image.fromarray(np.clip(gazette_icon(icon_w), 0, 255).astype(np.uint8), "RGBA")
    # warm glow behind the sheet
    glow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([W * 0.2, W * 0.2, W * 0.8, W * 0.8], fill=(255, 200, 120, 70))
    base.alpha_composite(glow.filter(ImageFilter.GaussianBlur(W * 0.06)))
    base.alpha_composite(icon, ((W - icon_w) // 2, (W - icon_w) // 2))
    base.resize((SIZE, SIZE), Image.LANCZOS).save(out)
    print(out)


if __name__ == "__main__":
    main()
