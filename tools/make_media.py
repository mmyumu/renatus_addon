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


def card_frame(size=128):
    """Card border, 9-slice (corners 32 px), light metal meant to be tinted by rarity."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float64) + 0.5
    d = np.minimum(np.minimum(x, size - x), np.minimum(y, size - y))
    img = band_color(d, [
        (0.0, (10, 8, 7, 255)), (1.0, (10, 8, 7, 255)),
        (1.3, (255, 255, 255, 255)), (3.0, (200, 200, 200, 255)), (5.0, (130, 130, 130, 255)),
        (5.3, (20, 16, 14, 255)), (6.3, (20, 16, 14, 255)),
        (6.6, (0, 0, 0, 140)), (12.0, (0, 0, 0, 0)), (999.0, (0, 0, 0, 0)),
    ])
    # corner studs: small bevelled diamonds on the band
    for cx, cy in [(5, 5), (size - 5, 5), (5, size - 5), (size - 5, size - 5)]:
        dd = np.abs(x - cx) + np.abs(y - cy)
        stud = dd < 7
        light = np.clip(0.6 - 0.08 * ((x - cx) + (y - cy)), 0.2, 1)
        col = lerp((90, 90, 90), (255, 255, 255), light)
        img[..., :3] = np.where(stud[..., None], col, img[..., :3])
        img[..., 3] = np.where(stud, 255, img[..., 3])
    return img


CARDBACK_V = 362 / 512  # used height of the cardback texture (card face is 126 x 178)


def card_back(w=256, h=512):
    """Back of an unknown card: red leather, gold frame, round medallion with a crowned R.

    Drawn in the card's own proportions (126 x 178) in the top of a 256 x 512
    texture; the addon crops it with SetTexCoord, so nothing is stretched.
    """
    from PIL import ImageDraw, ImageFilter
    S = 4
    uh = round(h * CARDBACK_V)
    W, H = w * S, uh * S
    y, x = np.mgrid[0:H, 0:W].astype(np.float64) + 0.5
    # leather, a bit warmer than the window's, with a soft vignette
    big = noise((H // S, W // S), 2.2, 130)
    pebble = smooth(0.45, 0.75, noise((H // S, W // S), 1.0, 131))
    grain = noise((H // S, W // S), 0.6, 132)
    base = lerp((40, 12, 10), (88, 26, 20), big)
    small = base * (0.82 + 0.18 * pebble[..., None] + (grain[..., None] - 0.5) * 0.2)
    bg = np.asarray(Image.fromarray(np.clip(small, 0, 255).astype(np.uint8), "RGB").resize((W, H), Image.BICUBIC)).astype(np.float64)
    c = (W / 2, H / 2)
    vig = np.hypot((x - c[0]) / W, (y - c[1]) / H)
    bg *= (1.08 - 0.75 * vig ** 2)[..., None]
    im = Image.fromarray(np.dstack([np.clip(bg, 0, 255), np.full((H, W), 255.0)]).astype(np.uint8), "RGBA")
    d = ImageDraw.Draw(im)
    gold, gold_dk, gold_hi = (214, 168, 82, 255), (120, 80, 30, 255), (255, 226, 150, 255)
    # double gold frame with small diamonds in the corners
    m1, m2 = 13 * S, 20 * S
    d.rectangle([m1, m1, W - m1, H - m1], outline=gold, width=3 * S)
    d.rectangle([m2, m2, W - m2, H - m2], outline=gold_dk, width=S)
    for cx, cy in ((m1, m1), (W - m1, m1), (m1, H - m1), (W - m1, H - m1)):
        r = 7 * S
        d.polygon([(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)], fill=gold, outline=gold_dk)
        d.ellipse([cx - 2 * S, cy - 2 * S, cx + 2 * S, cy + 2 * S], fill=(150, 24, 18, 255))
    # filigree: thin lines from the medallion towards top and bottom
    cx, cy = W / 2, H / 2
    R = 78 * S
    for sgn in (-1, 1):
        y0, y1 = cy + sgn * (R + 10 * S), (m2 + 14 * S) if sgn < 0 else (H - m2 - 14 * S)
        d.line([cx, y0, cx, y1], fill=gold_dk, width=2 * S)
        r = 6 * S
        d.polygon([(cx, y1 - r), (cx + r, y1), (cx, y1 + r), (cx - r, y1)], fill=gold)
    # medallion: dark shadow, gold rim (bevelled), red enamel disc
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse([cx - R - 4 * S, cy - R, cx + R + 4 * S, cy + R + 8 * S], fill=(0, 0, 0, 170))
    im.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(6 * S)))
    rr = np.hypot(x - cx, y - cy)
    light = np.clip(0.5 - 0.5 * ((x - cx) + (y - cy)) / R, 0, 1)
    arr = np.asarray(im).astype(np.float64)
    rim = (rr < R) & (rr >= R - 9 * S)
    rimcol = lerp((110, 72, 26), (255, 222, 140), light)
    arr[..., :3] = np.where(rim[..., None], rimcol, arr[..., :3])
    groove = (rr < R - 3.5 * S) & (rr >= R - 5 * S)
    arr[..., :3] = np.where(groove[..., None], (90, 56, 20), arr[..., :3])
    disc = rr < R - 9 * S
    enamel = lerp((70, 6, 6), (170, 28, 20), np.clip(1 - np.hypot(x - cx + R * 0.3, y - cy + R * 0.35) / (R * 1.4), 0, 1))
    arr[..., :3] = np.where(disc[..., None], enamel, arr[..., :3])
    inner = (rr < R - 13 * S) & (rr >= R - 14.5 * S)
    arr[..., :3] = np.where(inner[..., None], (200, 150, 70), arr[..., :3])
    im = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGBA")
    # the R, with a small crown above it: drawn as a mask, then gold-shaded and bevelled
    mask = Image.new("L", (W, H), 0)
    md = ImageDraw.Draw(mask)
    font = _serif(int(R * 1.12))
    if font:
        bb = md.textbbox((0, 0), "R", font=font)
        tw, th = bb[2] - bb[0], bb[3] - bb[1]
        md.text((cx - tw / 2 - bb[0], cy - th / 2 - bb[1] + R * 0.14), "R", font=font, fill=255)
    # crown: band + three points topped with pearls
    ct, cb_, cw = cy - R * 0.7, cy - R * 0.45, R * 0.36
    md.polygon([(cx - cw, cb_), (cx - cw, ct + R * 0.06), (cx - cw * 0.5, cb_ - R * 0.1), (cx, ct),
                (cx + cw * 0.5, cb_ - R * 0.1), (cx + cw, ct + R * 0.06), (cx + cw, cb_)], fill=255)
    for px, py in ((cx - cw, ct + R * 0.06), (cx, ct), (cx + cw, ct + R * 0.06)):
        pr = R * 0.055
        md.ellipse([px - pr, py - pr, px + pr, py + pr], fill=255)
    m = np.asarray(mask).astype(np.float64) / 255
    # bevel: compare the mask with a copy shifted towards the light
    blur = np.asarray(mask.filter(ImageFilter.GaussianBlur(2.5 * S))).astype(np.float64) / 255
    gy, gx = np.gradient(blur)
    bevel = np.clip(0.55 + (-(gx + gy)) * 14 * S, 0, 1)
    vert = np.clip((y - (cy - R)) / (2 * R), 0, 1)
    letter = lerp((255, 232, 160), (170, 112, 36), vert * 0.8)
    letter = letter * (0.55 + 0.75 * bevel[..., None])
    # dark outline + drop shadow under the letter
    out = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    om = mask.filter(ImageFilter.MaxFilter(2 * S + 1)).filter(ImageFilter.GaussianBlur(S))
    sh = Image.new("RGBA", (W, H), (30, 6, 4, 255))
    out.paste(sh, (2 * S, 3 * S), om)
    im.alpha_composite(out)
    arr = np.asarray(im).astype(np.float64)
    arr[..., :3] = arr[..., :3] * (1 - m[..., None]) + np.clip(letter, 0, 255) * m[..., None]
    im = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGBA")
    small = im.resize((w, uh), Image.LANCZOS)
    full = Image.new("RGBA", (w, h), (0, 0, 0, 255))
    full.paste(small, (0, 0))
    return np.asarray(full).astype(np.float64)


def gem(size=32):
    """Round gem, white, tinted by rarity."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float64) + 0.5
    c = size / 2
    r = np.hypot(x - c, y - c)
    img = rgba(size, size)
    shade = np.clip(1 - np.hypot(x - c + 4, y - c + 4) / (c * 1.3), 0, 1)
    img[..., :3] = lerp((70, 70, 70), (255, 255, 255), shade ** 0.7)[..., :3]
    rim = (r > c - 3.5) & (r < c - 1)
    img[..., :3] = np.where(rim[..., None], (40, 30, 20), img[..., :3])
    hi = np.hypot(x - c + 4, y - c + 4) < 2.5
    img[..., :3] = np.where(hi[..., None], (255, 255, 255), img[..., :3])
    img[..., 3] = 255 * np.clip(c - 1 - r, 0, 1)
    return img


def glow(size=128):
    """Soft radial glow (white), drawn behind epic and legendary cards."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float64) + 0.5
    c = size / 2
    r = np.hypot(x - c, y - c) / c
    img = rgba(size, size)
    img[..., :3] = 255
    img[..., 3] = 255 * np.clip(1 - r, 0, 1) ** 2
    return img


def holo(size=256):
    """Shiny cards: rainbow foil, diagonal bands with a faint interference pattern.
    Seamless in both directions (drawn with REPEAT, its texcoords scrolled)."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float64) + 0.5
    hue = ((x + y) / size * 2) % 1.0
    k = np.arange(3)[None, None, :]
    rgb = 0.5 + 0.5 * np.cos(2 * np.pi * (hue[..., None] - k / 3))
    bright = 0.55 + 0.45 * np.sin(2 * np.pi * (x - y) / size * 3) ** 2
    img = rgba(size, size)
    img[..., :3] = 255 * rgb * bright[..., None]
    img[..., 3] = 255
    return img


def sheen(w=256, h=256):
    """Shiny cards: a soft diagonal band of light, transparent elsewhere (edges included,
    the texture is drawn clamped and slid across the card)."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float64) + 0.5
    d = (x - w / 2) + (y - h / 2) * 0.45
    core = np.exp(-(d / 9) ** 2)
    halo = np.exp(-(d / 30) ** 2) * 0.35
    a = np.clip(core + halo, 0, 1)
    a[:, :2] = 0
    a[:, -2:] = 0
    img = rgba(h, w)
    img[..., :3] = (255, 250, 235)
    img[..., 3] = 255 * a
    return img


def sparkle(size=64):
    """Shiny cards: a four-pointed glint."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float64) + 0.5
    c = size / 2
    dx, dy = np.abs(x - c) / c, np.abs(y - c) / c
    rays = np.exp(-dx / 0.035) * np.exp(-dy / 0.45) + np.exp(-dy / 0.035) * np.exp(-dx / 0.45)
    core = np.exp(-(np.hypot(dx, dy) / 0.12) ** 2)
    a = np.clip(rays + core, 0, 1) * np.clip(1 - np.hypot(dx, dy), 0, 1)
    img = rgba(size, size)
    img[..., :3] = 255
    img[..., 3] = 255 * a
    return img


def _serif(px, bold=True):
    """A serif font for the masthead; None if none is installed (blocks are drawn instead)."""
    from PIL import ImageFont
    names = ["LiberationSerif-Bold.ttf", "DejaVuSerif-Bold.ttf"] if bold else ["LiberationSerif-Regular.ttf", "DejaVuSerif.ttf"]
    for d in ["/usr/share/fonts/truetype/liberation", "/usr/share/fonts/truetype/dejavu"]:
        for n in names:
            try:
                return ImageFont.truetype(os.path.join(d, n), px)
            except OSError:
                pass
    return None


def gazette_icon(size=128):
    """On-screen gazette widget: a front page, slightly tilted, with a folded corner.

    Drawn 4x larger then reduced, so lines stay crisp at 40 px: masthead between
    double rules, a red banner, a bold headline, an engraving, columns of text.
    """
    from PIL import ImageDraw, ImageFilter
    S = 4
    W = size * S
    ink, dim, red = (34, 22, 14, 255), (92, 72, 52, 255), (150, 30, 20, 255)
    # page, upright, then rotated onto the canvas
    pw, ph = int(W * 0.80), int(W * 0.94)
    page = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))
    paper_img = paper(512)
    tex = Image.fromarray(np.clip(paper_img, 0, 255).astype(np.uint8), "RGBA").resize((pw, ph))
    tex.putalpha(255)
    page.paste(tex, (0, 0))
    d = ImageDraw.Draw(page)
    m = int(pw * 0.08)                      # margin
    x0, x1 = m, pw - m
    y = int(ph * 0.05)
    # masthead
    d.rectangle([x0, y, x1, y + S * 1.2], fill=ink)
    y += int(S * 3)
    font = _serif(int(ph * 0.13))
    mh = int(ph * 0.12)
    if font:
        text = "GAZETTE"
        tw = d.textlength(text, font=font)
        scale = (x1 - x0) / tw
        f2 = _serif(int(ph * 0.13 * min(scale, 1.4)))
        tw = d.textlength(text, font=f2)
        bbox = d.textbbox((0, 0), text, font=f2)
        d.text(((pw - tw) / 2, y - bbox[1]), text, font=f2, fill=ink)
        mh = bbox[3] - bbox[1]
    else:
        d.rectangle([x0, y, x1, y + mh], fill=ink)
    y += mh + int(S * 2.5)
    d.rectangle([x0, y, x1, y + S * 0.8], fill=ink)
    y += int(S * 1.8)
    d.rectangle([x0, y, x1, y + S * 2.2], fill=ink)
    y += int(S * 4.5)
    # red banner across the page
    bh = int(ph * 0.075)
    d.rectangle([x0, y, x1, y + bh], fill=red)
    for i in range(5):  # pale "letters" in the banner
        bx = x0 + int((x1 - x0) * (0.1 + i * 0.17))
        d.rectangle([bx, y + bh * 0.3, bx + (x1 - x0) * 0.12, y + bh * 0.7], fill=(240, 214, 180, 255))
    y += bh + int(S * 3)
    # headline: two thick lines
    hl = int(ph * 0.05)
    d.rectangle([x0, y, x1, y + hl], fill=ink)
    y += hl + int(S * 2)
    d.rectangle([x0, y, x0 + (x1 - x0) * 0.72, y + hl], fill=ink)
    y += hl + int(S * 4)
    # engraving (left) and text columns
    colw = (x1 - x0 - S * 4) / 2
    iy0, iy1 = y, y + int(ph * 0.26)
    ix1 = int(x0 + colw)
    # engraving drawn on its own, so the hill stays inside its frame
    gw, gh = ix1 - x0, iy1 - iy0
    pic = Image.new("RGBA", (gw, gh), (120, 92, 62, 255))
    g = ImageDraw.Draw(pic)
    for i, t in enumerate(np.linspace(0, 1, gh)):  # sky to ground, hatched
        c = tuple(int(v) for v in lerp((204, 180, 140), (140, 108, 72), t)) + (255,)
        if i % S < S - 1:
            g.line([0, i, gw, i], fill=c)
    # a hill and a banner on a pole: a battle scene in miniature
    g.ellipse([-gw * 0.3, gh * 0.62, gw * 1.2, gh * 1.6], fill=(64, 46, 30, 255))
    fx = gw * 0.5
    g.rectangle([fx, gh * 0.16, fx + S * 1.2, gh * 0.68], fill=ink)
    g.polygon([(fx + S, gh * 0.16), (fx + gw * 0.34, gh * 0.25), (fx + S, gh * 0.34)], fill=red)
    page.paste(pic, (x0, iy0))
    d.rectangle([x0, iy0, ix1, iy1], outline=ink, width=S)
    # text lines
    def lines(xa, xb, ya, yb, seed):
        rng = np.random.default_rng(seed)
        yy = ya
        while yy + S * 1.6 < yb:
            end = xb if rng.random() > 0.18 else xa + (xb - xa) * rng.uniform(0.4, 0.8)
            d.rectangle([xa, yy, end, yy + S * 1.3], fill=dim)
            yy += S * 3.4
    lines(x0 + colw + S * 4, x1, iy0, iy1, 1)
    y = iy1 + int(S * 3.5)
    lines(x0, x0 + colw, y, ph - m, 2)
    lines(x0 + colw + S * 4, x1, y, ph - m, 3)
    d.line([x0 + colw + S * 2, iy1 + S * 3, x0 + colw + S * 2, ph - m], fill=dim, width=max(1, S // 2))
    # folded corner (bottom right)
    fc = int(pw * 0.2)
    d.polygon([(pw - fc, ph), (pw, ph - fc), (pw, ph)], fill=(0, 0, 0, 0))
    d.polygon([(pw - fc, ph), (pw, ph - fc), (pw - fc, ph - fc)], fill=(196, 172, 128, 255))
    d.line([(pw - fc, ph), (pw, ph - fc)], fill=(120, 92, 60, 255), width=S)
    # thin dark edge around the sheet
    edge = Image.new("L", (pw, ph), 0)
    ImageDraw.Draw(edge).rectangle([0, 0, pw - 1, ph - 1], outline=255, width=S)
    page.paste((110, 84, 56, 255), (0, 0), Image.composite(edge, Image.new("L", (pw, ph), 0), page.getchannel("A")))

    rot = page.rotate(6, resample=Image.BICUBIC, expand=True)
    if rot.height > W * 0.97:  # keep the whole sheet (and its shadow) on the canvas
        k = W * 0.97 / rot.height
        rot = rot.resize((int(rot.width * k), int(rot.height * k)), Image.LANCZOS)
    canvas = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ox, oy = (W - rot.width) // 2 - S, (W - rot.height) // 2 - S
    # soft shadow under the sheet
    shadow = Image.new("RGBA", rot.size, (0, 0, 0, 0))
    shadow.putalpha(rot.getchannel("A").point(lambda a: int(a * 0.6)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(S * 3))
    canvas.alpha_composite(shadow, (ox + S * 3, oy + S * 4))
    canvas.alpha_composite(rot, (ox, oy))
    small = canvas.resize((size, size), Image.LANCZOS)
    return np.asarray(small).astype(np.float64)


def _to_np(im):
    return np.asarray(im.convert("RGBA")).astype(np.float64)


def _sky(w, h, top, bottom, seed):
    y = np.linspace(0, 1, h)[:, None] * np.ones((1, w))
    col = lerp(top, bottom, y)
    col = col + (noise((h, w), 1.6, seed)[..., None] - 0.5) * 18
    img = rgba(h, w)
    img[..., :3] = col
    img[..., 3] = 255
    return img


def _ridge(img, base, amp, beta, seed, color, haze=0.0):
    """Mountain / foliage silhouette: filled below a noisy ridge line."""
    h, w = img.shape[:2]
    line = noise((1, w), beta, seed)[0]
    line = base * h - (line - 0.5) * amp * h
    y = np.arange(h)[:, None]
    k = np.clip(y - line[None, :] + 0.5, 0, 1)
    shade = np.clip((y - line[None, :]) / (h * 0.5), 0, 1)
    col = lerp(color, np.array(color) * 0.55, shade)
    col = lerp(col, img[..., :3], haze)
    img[..., :3] = img[..., :3] * (1 - k[..., None]) + col * k[..., None]
    return img


def cardbg_lieu(w=256, h=128):
    """Card backdrop for places: dusk sky, three mountain ranges, mist."""
    img = _sky(w, h, (96, 138, 184), (236, 196, 140), 50)
    img = _ridge(img, 0.55, 0.45, 1.8, 51, (92, 104, 128), haze=0.45)
    img = _ridge(img, 0.72, 0.35, 1.9, 52, (60, 84, 70), haze=0.2)
    img = _ridge(img, 0.88, 0.25, 2.0, 53, (34, 52, 36))
    return img


def cardbg_donjon(w=256, h=128):
    """Card backdrop for dungeons and exploits: stone wall, arch, torchlight."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float64) + 0.5
    stone = noise((h, w), 1.2, 60)
    img = rgba(h, w)
    img[..., :3] = lerp((46, 40, 38), (86, 76, 68), stone)
    # bricks
    row = (y // 16).astype(int)
    off = (row % 2) * 16
    mortar = ((y % 16) < 1.5) | (((x + off) % 32) < 1.5)
    img[..., :3] = np.where(mortar[..., None], img[..., :3] * 0.55, img[..., :3])
    # dark arch in the middle
    cx = w / 2
    r = np.hypot((x - cx) / 0.9, (y - h * 0.62))
    inside = (r < h * 0.42) | ((np.abs(x - cx) < h * 0.38) & (y > h * 0.62))
    img[..., :3] = np.where(inside[..., None], img[..., :3] * 0.18, img[..., :3])
    # torchlight on both sides
    for tx in (w * 0.12, w * 0.88):
        g = np.exp(-((x - tx) ** 2 + (y - h * 0.35) ** 2) / (2 * (h * 0.28) ** 2))
        img[..., :3] = img[..., :3] + g[..., None] * np.array((150, 80, 20))
    img[..., 3] = 255
    return img


def cardbg_guilde(w=256, h=128):
    """Card backdrop for people: red tapestry, gold lozenges, soft light behind the head."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float64) + 0.5
    cloth = noise((h, w), 0.9, 70)
    img = rgba(h, w)
    img[..., :3] = lerp((84, 14, 12), (128, 28, 22), cloth)
    u, v = (x % 32) - 16, (y % 32) - 16
    loz = np.abs(u) + np.abs(v)
    gold = (np.abs(loz - 11) < 1.2)
    img[..., :3] = np.where(gold[..., None], lerp(img[..., :3], (200, 150, 70), 0.55), img[..., :3])
    halo = np.exp(-((x - w / 2) ** 2 / (2 * (w * 0.22) ** 2) + (y - h * 0.4) ** 2 / (2 * (h * 0.45) ** 2)))
    img[..., :3] = img[..., :3] + halo[..., None] * np.array((90, 60, 30))
    img[..., 3] = 255
    return img


def cardbg_bestiaire(w=256, h=128):
    """Card backdrop for beasts: forest clearing, foliage silhouettes."""
    img = _sky(w, h, (120, 160, 110), (206, 214, 150), 80)
    img = _ridge(img, 0.45, 0.7, 2.4, 81, (54, 92, 50), haze=0.5)
    img = _ridge(img, 0.7, 0.6, 2.6, 82, (32, 64, 30), haze=0.15)
    img = _ridge(img, 0.92, 0.2, 1.4, 83, (70, 54, 30))
    return img


def cardbg_ennemi(w=256, h=128):
    """Card backdrop for enemies: blood-red dusk, smoke, claw marks."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float64) + 0.5
    img = _sky(w, h, (40, 10, 10), (150, 40, 20), 90)
    smoke = noise((h, w), 1.8, 91)
    img[..., :3] = lerp(img[..., :3], (30, 20, 20), smooth(0.45, 0.9, smoke) * 0.7)
    for i, off in enumerate((-18, 0, 18)):
        d = np.abs((x - w * 0.62 - off) - (y - h / 2) * 0.55)
        k = np.clip(2.2 - d, 0, 1) * ((y > h * 0.12) & (y < h * 0.88))
        img[..., :3] = lerp(img[..., :3], (12, 4, 4), k * 0.8)
    img[..., 3] = 255
    return img


def cardbg_presse(w=256, h=128):
    """Card backdrop for press cards (front pages, news items): sepia newsprint columns."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float64) + 0.5
    p = paper(256)[:h, :w, :3]
    img = rgba(h, w)
    img[..., :3] = p
    rng = np.random.default_rng(100)
    for col in range(4):
        x0, x1 = 10 + col * 61, 10 + col * 61 + 54
        yy = 10
        while yy < h - 8:
            end = x1 if rng.random() > 0.2 else x0 + (x1 - x0) * rng.uniform(0.4, 0.8)
            k = (x >= x0) & (x <= end) & (y >= yy) & (y < yy + 2)
            img[..., :3] = np.where(k[..., None], lerp(img[..., :3], (110, 88, 60), 0.6), img[..., :3])
            yy += 6
    img[..., 3] = 255
    return img


def cardbg_tresor(w=256, h=128):
    """Card backdrop for treasures: deep purple vault with gold sparkles."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float64) + 0.5
    img = _sky(w, h, (34, 18, 52), (86, 46, 96), 110)
    rng = np.random.default_rng(111)
    for _ in range(40):
        cx, cy, r = rng.uniform(0, w), rng.uniform(0, h), rng.uniform(0.6, 2.2)
        g = np.exp(-((x - cx) ** 2 + (y - cy) ** 2) / (2 * r * r))
        img[..., :3] = img[..., :3] + g[..., None] * np.array((255, 210, 120)) * rng.uniform(0.4, 1)
    halo = np.exp(-((x - w / 2) ** 2 + (y - h / 2) ** 2) / (2 * (h * 0.4) ** 2))
    img[..., :3] = img[..., :3] + halo[..., None] * np.array((80, 60, 20))
    img[..., 3] = 255
    return img


def booster(w=128, h=256):
    """Sealed booster pack: crimped foil ends, red body, gold emblem, the album's name."""
    from PIL import ImageDraw
    S = 4
    W, H = w * S, h * S
    y, x = np.mgrid[0:H, 0:W].astype(np.float64) + 0.5
    body = rgba(H, W)
    shine = np.clip(1 - np.abs((x / W) - 0.32 - (y / H) * 0.25) * 3.2, 0, 1)
    base = lerp((120, 20, 16), (170, 36, 26), noise((H, W), 1.4, 120))
    body[..., :3] = base + shine[..., None] * 70
    # side shading
    edge = np.minimum(x, W - x) / W
    body[..., :3] = body[..., :3] * (0.6 + 0.4 * smooth(0, 0.12, edge))[..., None]
    body[..., 3] = 255
    # crimped ends (silver foil with teeth)
    crimp = (y < H * 0.075) | (y > H * 0.925)
    teeth = (np.sin(x / W * np.pi * 36) > 0)
    foil = lerp((150, 150, 160), (230, 230, 240), noise((H, W), 0.8, 121))
    body[..., :3] = np.where(crimp[..., None], foil * np.where(teeth, 1.0, 0.8)[..., None], body[..., :3])
    zig = (y < H * 0.02 + (np.abs(((x / W * 36) % 1) - 0.5)) * H * 0.02) | (y > H * 0.98 - (np.abs(((x / W * 36) % 1) - 0.5)) * H * 0.02)
    body[..., 3] = np.where(zig, 0, 255)
    im = Image.fromarray(np.clip(body, 0, 255).astype(np.uint8), "RGBA")
    d = ImageDraw.Draw(im)
    gold, dark = (232, 186, 92, 255), (60, 10, 8, 255)
    # gold frame
    d.rectangle([W * 0.08, H * 0.1, W * 0.92, H * 0.9], outline=gold, width=S * 2)
    # emblem: a fan of three cards
    cx, cy = W / 2, H * 0.47
    for ang, col in ((-22, (210, 200, 170, 255)), (0, (236, 226, 196, 255)), (22, (210, 200, 170, 255))):
        card = Image.new("RGBA", (int(W * 0.34), int(W * 0.48)), (0, 0, 0, 0))
        cd = ImageDraw.Draw(card)
        cd.rounded_rectangle([0, 0, card.width - 1, card.height - 1], radius=S * 3, fill=col, outline=gold, width=S * 2)
        cd.ellipse([card.width * 0.3, card.height * 0.3, card.width * 0.7, card.height * 0.58], fill=(150, 30, 20, 255))
        rot = card.rotate(-ang, resample=Image.BICUBIC, expand=True)
        im.alpha_composite(rot, (int(cx - rot.width / 2 + ang * S * 0.9), int(cy - rot.height / 2)))
    font = _serif(int(H * 0.06))
    for text, ty, size in (("RENATUS", H * 0.16, 0.075), ("BOOSTER", H * 0.74, 0.06), ("5 cartes", H * 0.82, 0.04)):
        f = _serif(int(H * size)) or font
        if f:
            tw = d.textlength(text, font=f)
            d.text(((W - tw) / 2 + S, ty + S), text, font=f, fill=dark)
            d.text(((W - tw) / 2, ty), text, font=f, fill=gold)
    return np.asarray(im.resize((w, h), Image.LANCZOS)).astype(np.float64)


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
    "cardframe": card_frame,
    "cardback": card_back,
    "gem": gem,
    "glow": glow,
    "holo": holo,
    "sheen": sheen,
    "sparkle": sparkle,
    "gazette": gazette_icon,
    "booster": booster,
    "cardbg_lieu": cardbg_lieu,
    "cardbg_donjon": cardbg_donjon,
    "cardbg_guilde": cardbg_guilde,
    "cardbg_bestiaire": cardbg_bestiaire,
    "cardbg_ennemi": cardbg_ennemi,
    "cardbg_presse": cardbg_presse,
    "cardbg_tresor": cardbg_tresor,
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
