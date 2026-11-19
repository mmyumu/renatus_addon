# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow", "numpy"]
# ///
"""Generates the addon textures (Renatus/Media/*.tga) procedurally.

Run with:  uv run tools/make_media.py [--preview DIR]

Every texture is deterministic (fixed seeds) and power-of-two sized, as WoW
expects. --preview also writes PNG copies, handy to look at them.
"""
import argparse
import os

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Renatus", "Media")


# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------
def noise(size, beta, seed):
    """Tileable fractal noise in [0, 1] (1/f^beta spectrum, periodic by construction)."""
    h, w = size if isinstance(size, tuple) else (size, size)
    rng = np.random.default_rng(seed)
    white = rng.standard_normal((h, w))
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.fftfreq(w)[None, :]
    f = np.sqrt(fx * fx + fy * fy)
    f[0, 0] = 1
    spec = np.fft.fft2(white) / f ** beta
    spec[0, 0] = 0
    n = np.real(np.fft.ifft2(spec))
    n -= n.min()
    return n / n.max()


def rgba(h, w):
    return np.zeros((h, w, 4), dtype=np.float64)


def lerp(a, b, t):
    a = np.asarray(a, dtype=np.float64)
    b = np.asarray(b, dtype=np.float64)
    t = np.asarray(t, dtype=np.float64)[..., None]
    return a + (b - a) * t


def smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def save(name, img, preview):
    arr = np.clip(img, 0, 255).astype(np.uint8)
    im = Image.fromarray(arr, "RGBA")
    im.save(os.path.join(OUT, name + ".tga"), compression=None)
    if preview:
        im.save(os.path.join(preview, name + ".png"))
    return im


def band_color(d, profile):
    """Colour of a border band as a function of distance d to the outer edge.
    profile: list of (distance, (r, g, b, a)); linear between stops."""
    ds = [p[0] for p in profile]
    out = np.zeros(d.shape + (4,))
    for c in range(4):
        out[..., c] = np.interp(d, ds, [p[1][c] for p in profile])
    return out


# ----------------------------------------------------------------------------
# textures
# ----------------------------------------------------------------------------
def leather(size=256):
    """Dark red leather, tileable."""
    big = noise(size, 2.2, 1)
    mid = noise(size, 1.4, 2)
    grain = noise(size, 0.6, 3)
    # pebbled leather: small cells from thresholded mid-high noise
    pebble = smooth(0.45, 0.75, noise(size, 1.0, 4))
    base = lerp((22, 9, 8), (52, 18, 14), big * 0.7 + mid * 0.3)
    shade = 0.82 + 0.18 * pebble[..., None] + (grain[..., None] - 0.5) * 0.18
    img = rgba(size, size)
    img[..., :3] = base * shade
    img[..., 3] = 255
    return img


def frame(size=256, corner=64):
    """Main window border, 9-slice (corners `corner` px). Centre transparent."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float64) + 0.5
    d = np.minimum(np.minimum(x, size - x), np.minimum(y, size - y))
    tex = noise(size, 1.2, 10)
    profile = [
        (0.0, (8, 6, 5, 255)), (1.5, (8, 6, 5, 255)),
        (2.0, (196, 150, 74, 255)), (3.5, (150, 108, 52, 255)),
        (5.0, (64, 56, 52, 255)), (11.0, (48, 42, 39, 255)), (16.0, (30, 26, 24, 255)),
        (16.5, (14, 11, 9, 255)), (17.5, (14, 11, 9, 255)),
        (18.0, (222, 176, 86, 255)), (19.5, (150, 104, 44, 255)),
        (20.0, (10, 6, 5, 255)), (21.0, (10, 6, 5, 230)),
        (22.0, (0, 0, 0, 150)), (30.0, (0, 0, 0, 0)), (999.0, (0, 0, 0, 0)),
    ]
    img = band_color(d, profile)
    iron = (d > 4.5) & (d < 16.5)
    img[..., :3] += np.where(iron[..., None], (tex[..., None] - 0.5) * 26, 0)

    # Corner ornaments: bevelled diamond plate with a garnet in the middle.
    for cx, cy in [(17, 17), (size - 17, 17), (17, size - 17), (size - 17, size - 17)]:
        dd = np.abs(x - cx) + np.abs(y - cy)
        r = 22.0
        plate = dd < r
        # bevel: light from top-left
        lx = (x - cx) / r
        ly = (y - cy) / r
        bevel = np.clip(1 - dd / r, 0, 1)
        light = np.clip(0.55 - 0.45 * (lx + ly) * (1 - bevel), 0.15, 1.0)
        gold = lerp((90, 60, 24), (236, 192, 100), light)
        rim = smooth(r - 1.0, r - 3.5, dd)  # 0 at the edge, 1 inside
        inner = dd < r - 5
        plate_col = np.where(inner[..., None], lerp((40, 34, 32), (88, 78, 70), light), gold)
        alpha = np.clip((r - dd) * 1.5, 0, 1)
        img[..., :3] = np.where(plate[..., None], plate_col * (0.6 + 0.4 * rim[..., None]), img[..., :3])
        img[..., 3] = np.maximum(img[..., 3], alpha * 255)
        # garnet
        gd = np.hypot(x - cx, y - cy)
        g = gd < 6.5
        gl = np.clip(1 - np.hypot(x - cx + 2.2, y - cy + 2.2) / 6.5, 0, 1)
        gem = lerp((70, 4, 6), (220, 40, 34), gl ** 0.8)
        gem = np.where((np.hypot(x - cx + 2.3, y - cy + 2.3) < 1.6)[..., None], (255, 210, 190), gem)
        img[..., :3] = np.where(g[..., None], gem, img[..., :3])
        ring = (gd >= 6.5) & (gd < 8.0)
        img[..., :3] = np.where(ring[..., None], (60, 40, 18), img[..., :3])
    return img


def panel(size=64):
    """Inner panel border, 9-slice (corners 16 px). Centre transparent."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float64) + 0.5
    d = np.minimum(np.minimum(x, size - x), np.minimum(y, size - y))
    profile = [
        (0.0, (4, 3, 3, 255)), (1.0, (4, 3, 3, 255)),
        (1.2, (150, 110, 56, 255)), (2.2, (110, 78, 38, 255)),
        (2.5, (10, 7, 6, 255)), (3.3, (10, 7, 6, 255)),
        (3.5, (0, 0, 0, 120)), (9.0, (0, 0, 0, 0)), (999.0, (0, 0, 0, 0)),
    ]
    img = band_color(d, profile)
    # corner brackets: small bronze L-shaped plates
    for sx, sy in [(1, 1), (-1, 1), (1, -1), (-1, -1)]:
        ox = 0 if sx > 0 else size
        oy = 0 if sy > 0 else size
        lx = (x - ox) * sx
        ly = (y - oy) * sy
        bracket = ((lx < 11) & (ly < 4.5)) | ((ly < 11) & (lx < 4.5))
        bracket &= (lx >= 0) & (ly >= 0)
        light = np.clip(1.0 - (lx + ly) / 22, 0, 1)
        col = lerp((96, 66, 30), (214, 168, 88), light)
        img[..., :3] = np.where(bracket[..., None], col, img[..., :3])
        img[..., 3] = np.where(bracket, 255, img[..., 3])
        rv = np.hypot(lx - 2.6, ly - 2.6)
        img[..., :3] = np.where((rv < 1.6)[..., None], (250, 222, 150), img[..., :3])
    return img


def header(w=512, h=128):
    """Title banner: dark red, gold trim at the bottom."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float64) + 0.5
    t = y / h
    col = lerp((60, 12, 9), (104, 22, 15), smooth(0.0, 0.55, t))
    col = lerp(col, (34, 7, 5), smooth(0.55, 1.0, t))
    n = noise((h, w), 1.6, 20)
    col = col * (0.88 + 0.24 * n[..., None])
    img = rgba(h, w)
    img[..., :3] = col
    img[..., 3] = 255
    # bottom trim: dark, gold, dark
    for y0, y1, c in [(h - 9, h - 7, (16, 8, 6)), (h - 7, h - 4, (214, 168, 80)), (h - 4, h - 3, (120, 84, 36)),
                      (h - 3, h, (16, 8, 6))]:
        img[y0:y1, :, :3] = c
    # top highlight
    img[0:2, :, :3] = (130, 50, 34)
    # fade both ends so the banner melts into the frame
    fade = smooth(0, 70, x) * smooth(0, 70, w - x)
    img[..., 3] = 255 * (0.25 + 0.75 * fade)
    return img


def nav_selected(w=256, h=64):
    """Selected tab: red glow from the left, gold bar, gold hairlines."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float64) + 0.5
    fx = 1 - smooth(0, w, x)
    col = lerp((70, 12, 8), (150, 32, 18), 0.5 + 0.5 * np.sin(np.pi * y / h))
    img = rgba(h, w)
    img[..., :3] = col
    img[..., 3] = 235 * fx ** 0.8
    hair = (y < 1.5) | (y > h - 1.5)
    img[..., :3] = np.where(hair[..., None], (220, 170, 80), img[..., :3])
    img[..., 3] = np.where(hair, 255 * fx ** 1.2, img[..., 3])
    bar = x < 4
    img[..., :3] = np.where(bar[..., None], lerp((150, 104, 40), (250, 206, 110), np.sin(np.pi * y / h)), img[..., :3])
    img[..., 3] = np.where(bar, 255, img[..., 3])
    return img


def button(w=16, h=32):
    """Button face: vertical red gradient (stretched horizontally)."""
    y = np.mgrid[0:h, 0:w][0].astype(np.float64) + 0.5
    t = y / h
    col = lerp((128, 30, 20), (58, 10, 7), t)
    img = rgba(h, w)
    img[..., :3] = col
    img[..., 3] = 255
    img[1:2, :, :3] = (176, 72, 50)
    return img


def section(w=512, h=32):
    """Section heading bar: red fading to the right, gold rule at the bottom."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float64) + 0.5
    fx = 1 - smooth(0, w, x)
    img = rgba(h, w)
    img[..., :3] = lerp((60, 12, 8), (96, 20, 13), np.sin(np.pi * y / h))
    img[..., 3] = 200 * fx
    rule = y > h - 2
    img[..., :3] = np.where(rule[..., None], (212, 166, 80), img[..., :3])
    img[..., 3] = np.where(rule, 255 * fx ** 0.7, img[..., 3])
    return img


def shade(w=16, h=256):
    """Vertical shading for panels: clear at the top, darker at the bottom."""
    y = np.mgrid[0:h, 0:w][0].astype(np.float64) + 0.5
    img = rgba(h, w)
    img[..., 3] = 130 * smooth(0, h, y)
    return img


def paper(size=512):
    """Aged newsprint with deckled edges."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float64) + 0.5
    stains = noise(size, 2.4, 30)
    fibres = noise(size, 0.4, 31)
    mid = noise(size, 1.3, 32)
    col = lerp((236, 226, 200), (214, 196, 156), smooth(0.35, 0.9, stains) * 0.8 + mid * 0.2)
    col = col + (fibres[..., None] - 0.5) * 12
    # edge vignette
    d = np.minimum(np.minimum(x, size - x), np.minimum(y, size - y)) / size
    vig = 1 - smooth(0.0, 0.07, d)
    col = lerp(col, (168, 138, 92), vig * 0.75)
    # foxing spots
    rng = np.random.default_rng(33)
    for _ in range(9):
        cx, cy = rng.uniform(30, size - 30, 2)
        r = rng.uniform(3, 11)
        k = np.exp(-((x - cx) ** 2 + (y - cy) ** 2) / (2 * r * r))
        col = lerp(col, (190, 150, 100), k * rng.uniform(0.15, 0.35))
    img = rgba(size, size)
    img[..., :3] = col
    # deckled edges
    edge = noise(size, 1.0, 34) * 5 + 1.0
    dpx = np.minimum(np.minimum(x, size - x), np.minimum(y, size - y))
    img[..., 3] = 255 * np.clip(dpx - edge, 0, 1)
    return img


def close_button(size=32):
    """Square close button: red plate, gold rim, gold cross."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float64) + 0.5
    d = np.minimum(np.minimum(x, size - x), np.minimum(y, size - y))
    img = band_color(d, [
        (0.0, (10, 6, 5, 255)), (1.0, (10, 6, 5, 255)),
        (1.3, (230, 182, 92, 255)), (3.0, (150, 104, 44, 255)),
        (3.3, (20, 8, 6, 255)), (4.0, (20, 8, 6, 255)),
        (4.3, (120, 26, 17, 255)), (16.0, (70, 12, 8, 255)), (99.0, (70, 12, 8, 255)),
    ])
    c = size / 2
    u = (x - c)
    v = (y - c)
    dist = np.minimum(np.abs(u - v), np.abs(u + v)) / np.sqrt(2)
    inside = (np.abs(u) < 7.5) & (np.abs(v) < 7.5)
    k = np.clip(2.2 - dist, 0, 1) * inside
    img[..., :3] = lerp(img[..., :3], (250, 210, 120), k)
    return img


def ring(size=64):
    """Gold medallion ring around the header crest."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float64) + 0.5
    c = size / 2
    r = np.hypot(x - c, y - c)
    img = band_color(c - r, [
        (-99, (0, 0, 0, 0)), (-0.5, (0, 0, 0, 0)), (0.5, (12, 8, 6, 255)), (1.5, (12, 8, 6, 255)),
        (2.0, (240, 196, 104, 255)), (4.5, (150, 104, 44, 255)), (5.0, (90, 60, 24, 255)),
        (5.5, (12, 8, 6, 255)), (6.5, (12, 8, 6, 255)), (7.0, (0, 0, 0, 0)), (99, (0, 0, 0, 0)),
    ])
    light = np.clip(0.5 - 0.5 * ((x - c) + (y - c)) / c, 0, 1)
    gold = (c - r > 1.5) & (c - r < 5.5)
    img[..., :3] = np.where(gold[..., None], img[..., :3] * (0.65 + 0.6 * light[..., None]), img[..., :3])
    return img


TEXTURES = {
    "leather": leather,
    "frame": frame,
    "panel": panel,
    "header": header,
    "navsel": nav_selected,
    "button": button,
    "section": section,
    "shade": shade,
    "paper": paper,
    "close": close_button,
    "ring": ring,
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", help="also write PNG copies to this directory")
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    if args.preview:
        os.makedirs(args.preview, exist_ok=True)
    for name, fn in TEXTURES.items():
        save(name, fn(), args.preview)
        print("Media/" + name + ".tga")


if __name__ == "__main__":
    main()
