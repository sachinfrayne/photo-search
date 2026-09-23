#!/usr/bin/env python3
"""Generates icon.icns for PhotoSearch. Run once (needs Pillow), then build_mac.sh.

    uv run --with pillow python make_icon.py
"""
import os
import shutil
import subprocess

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024


def gradient(top, bottom):
    img = Image.new("RGB", (SIZE, SIZE))
    d = ImageDraw.Draw(img)
    for y in range(SIZE):
        t = y / (SIZE - 1)
        d.line([(0, y), (SIZE, y)], fill=tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img


# Background: rounded square, teal → deep blue.
mask = Image.new("L", (SIZE, SIZE), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=SIZE // 5, fill=255)
img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
img.paste(gradient((56, 189, 196), (37, 72, 176)).convert("RGBA"), mask=mask)

# A photo print, slightly tilted, with a soft shadow.
photo = Image.new("RGBA", (560, 460), (0, 0, 0, 0))
pd = ImageDraw.Draw(photo)
pd.rounded_rectangle([0, 0, 559, 459], radius=28, fill="white")
pd.rounded_rectangle([34, 34, 525, 425], radius=14, fill=(255, 214, 140))
pd.ellipse([390, 70, 470, 150], fill=(255, 250, 225))                       # sun
pd.polygon([(34, 425), (200, 190), (330, 330), (400, 260), (525, 425)], fill=(58, 140, 110))  # hills
photo = photo.rotate(-8, resample=Image.BICUBIC, expand=True)
shadow = Image.new("RGBA", photo.size, (0, 0, 0, 0))
shadow.paste((0, 0, 0, 90), mask=photo.split()[3])
shadow = shadow.filter(ImageFilter.GaussianBlur(18))
img.alpha_composite(shadow, (150, 190))
img.alpha_composite(photo, (135, 165))

# Magnifying glass over the corner.
lens = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
d = ImageDraw.Draw(lens)
cx, cy, r = 640, 600, 170
d.line([(cx + 110, cy + 110), (cx + 250, cy + 250)], fill=(30, 40, 70, 255), width=70)
d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(255, 255, 255, 60), outline=(255, 255, 255, 255), width=44)
img.alpha_composite(lens)

img.save("icon.png")

# Build the .icns with the system's iconutil.
iconset = "icon.iconset"
shutil.rmtree(iconset, ignore_errors=True)
os.makedirs(iconset)
for size in (16, 32, 128, 256, 512):
    img.resize((size, size), Image.LANCZOS).save(f"{iconset}/icon_{size}x{size}.png")
    img.resize((size * 2, size * 2), Image.LANCZOS).save(f"{iconset}/icon_{size}x{size}@2x.png")
subprocess.run(["iconutil", "-c", "icns", iconset, "-o", "icon.icns"], check=True)
shutil.rmtree(iconset)
print("Wrote icon.icns")
