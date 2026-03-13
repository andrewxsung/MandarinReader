#!/usr/bin/env python3
"""
Generate simple placeholder icons for the Chrome extension.
Run once: python generate_icons.py
Requires: pip install Pillow
"""
try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("Install Pillow first: pip install Pillow")
    raise

SIZES = [16, 48, 128]
BG_COLOR = (192, 57, 43)   # #c0392b — red
TEXT_COLOR = (255, 255, 255)

for size in SIZES:
    img = Image.new("RGBA", (size, size), BG_COLOR)
    draw = ImageDraw.Draw(img)

    # Draw "M" as a simple text label (for MandarinReader)
    char = "M"
    font_size = max(int(size * 0.6), 8)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", font_size)
    except Exception:
        font = ImageFont.load_default()

    bbox = draw.textbbox((0, 0), char, font=font)
    w = bbox[2] - bbox[0]
    h = bbox[3] - bbox[1]
    x = (size - w) // 2 - bbox[0]
    y = (size - h) // 2 - bbox[1]
    draw.text((x, y), char, font=font, fill=TEXT_COLOR)

    path = f"icons/icon{size}.png"
    img.save(path)
    print(f"Saved {path}")

print("Done.")
