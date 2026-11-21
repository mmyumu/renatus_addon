# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow", "numpy"]
# ///
"""Generates the corner pieces that hold a card's force and endurance.

Run with:  uv run tools/make_stat_corner.py [--preview DIR]

Two textures, both drawn for the top left corner (the addon mirrors them for the right):
  statfill.tga  the plate, in grey levels (tinted in game: red force, green endurance)
  statrim.tga   its gold rim along the inner edge, and the shadow it casts on the art
The plate is a tab: a straight edge down from the top of the card, then an ogee sweeping
out to its left side. The top and left sides lie on the card frame, so they have no rim.
"""
import argparse
import os

import numpy as np

from make_media import OUT, band_color, noise, save, smooth

S = 128          # texture size (power of two)
EDGE = 0.62      # x of the straight edge, as a share of the width
KNEE = 0.48      # where the straight edge turns into the ogee, as a share of the height


def edge_x(t):
    """x of the inner edge at height t in [0, 1] (both as shares of the texture)."""
    t = np.asarray(t, dtype=np.float64)
    u = np.clip((t - KNEE) / (1 - KNEE), 0, 1)
    # ogee from the knee to the left side, with a small outward flourish at the knee
    sweep = 1 - u * u * (3 - 2 * u)
    flourish = 0.13 * np.sin(np.pi * u) * (1 - u) ** 2
    return np.where(t < KNEE, EDGE, EDGE * sweep + flourish)


def signed_distance():
    """Distance in texture pixels to the inner edge: > 0 on the plate, < 0 outside."""
    y, x = np.mgrid[0:S, 0:S].astype(np.float64) + 0.5
    ts = np.linspace(0, 1, 600)
    bx, by = edge_x(ts) * S, ts * S
    d = np.full((S, S), np.inf)
    for px, py in zip(bx, by):
        d = np.minimum(d, np.hypot(x - px, y - py))
    inside = x < edge_x(y / S) * S
    return np.where(inside, d, -d), x, y


def statfill(sd, x, y):
    """Light grey plate, brightest in the corner, darker towards its rim."""
    img = np.zeros((S, S, 4))
    corner = np.clip(1 - np.hypot(x, y) / (S * 0.95), 0, 1)
    tone = 0.62 + 0.38 * corner ** 1.5
    tone *= 0.72 + 0.28 * smooth(0, 16, sd)          # bevel: shade along the rim
    tone += 0.05 * (noise(S, 1.2, 41) - 0.5)          # a little grain
    img[..., :3] = np.clip(tone, 0, 1)[..., None] * 255
    img[..., 3] = smooth(-0.8, 0.8, sd) * 255
    return img


def statrim(sd, x, y):
    """Gold band along the inner edge, dark lines on both sides, soft shadow outside."""
    img = band_color(sd, [
        (-99, (0, 0, 0, 0)), (-9, (0, 0, 0, 0)), (-1.0, (0, 0, 0, 150)),
        (0.0, (12, 8, 6, 255)), (1.5, (12, 8, 6, 255)),
        (2.2, (255, 230, 150, 255)), (4.5, (226, 172, 74, 255)), (7.5, (128, 86, 30, 255)),
        (8.2, (12, 8, 6, 255)), (9.2, (12, 8, 6, 200)), (10.5, (0, 0, 0, 0)),
        # thin inner fillet, set into the plate
        (12.5, (0, 0, 0, 0)), (13.0, (240, 200, 110, 210)), (14.2, (180, 130, 60, 210)),
        (14.7, (0, 0, 0, 0)), (99, (0, 0, 0, 0)),
    ])
    gold = ((sd > 1.8) & (sd < 8.0)) | ((sd > 12.5) & (sd < 14.7))
    light = np.clip(1.2 - 0.6 * (x + y) / S, 0.7, 1.2)
    img[..., :3] = np.where(gold[..., None], np.clip(img[..., :3] * light[..., None], 0, 255), img[..., :3])
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", help="also write PNG copies to this directory")
    args = ap.parse_args()
    if args.preview:
        os.makedirs(args.preview, exist_ok=True)
    sd, x, y = signed_distance()
    for name, fn in (("statfill", statfill), ("statrim", statrim)):
        save(name, fn(sd, x, y), args.preview)
        print("Media/" + name + ".tga")


if __name__ == "__main__":
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    main()
