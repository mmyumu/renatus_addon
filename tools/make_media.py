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


def card_back(size=256):
    """Back of an unknown card: red leather, gold frame, compass-rose emblem."""
    img = leather(size)
    img[..., :3] *= 1.6
    y, x = np.mgrid[0:size, 0:size].astype(np.float64) + 0.5
    d = np.minimum(np.minimum(x, size - x), np.minimum(y, size - y))
    gold = (210, 165, 80)
    for d0, d1 in [(14, 17), (22, 23.5)]:
        m = (d >= d0) & (d < d1)
        img[..., :3] = np.where(m[..., None], gold, img[..., :3])
    c = size / 2
    u, v = x - c, y - c
    r = np.hypot(u, v)
    ring = (r > 52) & (r < 56)
    img[..., :3] = np.where(ring[..., None], gold, img[..., :3])
    # four-pointed star (two rotated rhombi)
    star = ((np.abs(u) / 14 + np.abs(v) / 64) < 1) | ((np.abs(u) / 64 + np.abs(v) / 14) < 1)
    star2 = ((np.abs(u + v) / 20 + np.abs(u - v) / 60) < 1) | ((np.abs(u + v) / 60 + np.abs(u - v) / 20) < 1)
    light = np.clip(0.6 - (u + v) / 140, 0.3, 1)
    img[..., :3] = np.where(star2[..., None], lerp((120, 84, 30), (200, 160, 80), light), img[..., :3])
    img[..., :3] = np.where(star[..., None], lerp((150, 104, 40), (255, 220, 130), light), img[..., :3])
    gem = r < 9
    img[..., :3] = np.where(gem[..., None], lerp((90, 6, 6), (230, 50, 40), np.clip(1 - np.hypot(u + 3, v + 3) / 9, 0, 1)), img[..., :3])
    return img


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
    "gazette": gazette_icon,
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
