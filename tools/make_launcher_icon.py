# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow"]
# ///
"""Draws the launcher icon (an open book on leather) into launcher/src-tauri/icons.

Run with:  uv run tools/make_launcher_icon.py
"""
import os

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "launcher", "src-tauri", "icons")
S = 1024  # drawn large, then downscaled for clean edges


def draw() -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # leather tile with a gold rim
    d.rounded_rectangle((40, 40, S - 40, S - 40), radius=180, fill=(94, 26, 22), outline=(212, 160, 23), width=36)
    # open book: two pages meeting at the spine
    left = [(180, 300), (500, 360), (500, 800), (180, 740)]
    right = [(S - 180, 300), (S - 500, 360), (S - 500, 800), (S - 180, 740)]
    for page in (left, right):
        d.polygon(page, fill=(236, 220, 192), outline=(120, 84, 40))
    d.line([(512, 350), (512, 810)], fill=(120, 84, 40), width=16)
    # text lines
    for i in range(5):
        y = 420 + i * 62
        d.line([(230, y - 6 + i * 2), (450, y + 30 + i * 2)], fill=(150, 120, 80), width=14)
        d.line([(S - 230, y - 6 + i * 2), (S - 450, y + 30 + i * 2)], fill=(150, 120, 80), width=14)
    # gold bookmark ribbon
    d.polygon([(540, 360), (600, 360), (600, 900), (570, 860), (540, 900)], fill=(212, 160, 23))
    return img


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    big = draw()
    big.resize((512, 512), Image.LANCZOS).save(os.path.join(OUT, "icon.png"))
    big.save(os.path.join(OUT, "icon.ico"), sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print("icons ->", OUT)


if __name__ == "__main__":
    main()
