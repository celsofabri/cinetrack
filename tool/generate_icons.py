"""Regenerates every app icon from one vector-like drawing (Concept 1: play + progress).

Usage: python3 tool/generate_icons.py   (needs Pillow)
"""
from PIL import Image, ImageDraw, ImageChops
import os

S = 1024 * 4  # supersampled canvas
PURPLE_TOP, PURPLE_BOT = (124, 77, 206), (88, 44, 160)
LAVENDER, AMBER = (233, 216, 253), (255, 193, 7)


def rounded_poly(pts, sigma):
    """Sharp polygon mask, blurred then thresholded: rounds convex corners evenly."""
    from PIL import ImageFilter
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    m = m.filter(ImageFilter.GaussianBlur(sigma))
    return m.point(lambda v: 255 if v >= 128 else 0).filter(ImageFilter.GaussianBlur(3))


def symbol_mask_and_fill(scale, cx0=0.5, cy0=0.5):
    """Returns RGBA layer with the play symbol, scaled around the canvas center."""
    def P(x, y):
        return ((cx0 + (x - 0.5) * scale) * S, (cy0 + (y - 0.5) * scale) * S)
    tri = [P(0.33, 0.21), P(0.83, 0.50), P(0.33, 0.79)]
    mask = rounded_poly(tri, 0.035 * scale * S)
    layer = Image.new("RGBA", (S, S), LAVENDER + (255,))
    # progress fill: lower part of the triangle in amber, diagonal boundary
    fill = Image.new("L", (S, S), 0)
    ImageDraw.Draw(fill).polygon([P(0.0, 0.58), P(0.9, 0.36), P(0.9, 1.0), P(0.0, 1.0)], fill=255)
    amber = Image.new("RGBA", (S, S), AMBER + (255,))
    layer = Image.composite(amber, layer, fill)
    layer.putalpha(mask)
    return layer


def background(rounded):
    bg = Image.new("RGBA", (S, S))
    px = ImageDraw.Draw(bg)
    for y in range(S):
        t = y / (S - 1)
        c = tuple(int(PURPLE_TOP[i] + (PURPLE_BOT[i] - PURPLE_TOP[i]) * t) for i in range(3))
        px.line([(0, y), (S, y)], fill=c + (255,))
    if rounded:
        m = Image.new("L", (S, S), 0)
        ImageDraw.Draw(m).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.225), fill=255)
        bg.putalpha(m)
    return bg


def make(rounded=True, scale=1.0, with_bg=True):
    img = background(rounded) if with_bg else Image.new("RGBA", (S, S), (0, 0, 0, 0))
    img.alpha_composite(symbol_mask_and_fill(scale))
    return img


def save(img, path, size):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.resize((size, size), Image.LANCZOS).save(path)

rounded = make(rounded=True)
square = make(rounded=False)             # iOS: OS applies its own mask, no alpha allowed
maskable = make(rounded=False, scale=0.72)  # PWA maskable: keep inside the safe zone
symbol = make(with_bg=False, scale=1.25)

# Web
save(rounded, "web/icons/Icon-192.png", 192)
save(rounded, "web/icons/Icon-512.png", 512)
save(maskable, "web/icons/Icon-maskable-192.png", 192)
save(maskable, "web/icons/Icon-maskable-512.png", 512)
save(rounded, "web/favicon.png", 64)

# Android (legacy launcher icons)
for d, px in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
    save(rounded, f"android/app/src/main/res/mipmap-{d}/ic_launcher.png", px)

# iOS: every size already listed in the appiconset (opaque, no rounded corners)
import json
cj = json.load(open("ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json"))
for e in cj["images"]:
    w = float(e["size"].split("x")[0]) * int(e["scale"].rstrip("x"))
    flat = square.convert("RGB")
    flat.resize((int(w), int(w)), Image.LANCZOS).save(
        "ios/Runner/Assets.xcassets/AppIcon.appiconset/" + e["filename"])

# In-app logo (symbol only, transparent background)
save(symbol, "assets/logo.png", 256)


# ---- Splash logo (icon + wordmark, white text, transparent background) ----
# Uses a macOS system font; the generated PNGs are committed, so other
# platforms only need the font if they re-run this script.
from PIL import ImageFont

FONT = "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf"


def make_splash_logo(width):
    W, H = 900, 760
    canvas = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sym = symbol.resize((420, 420), Image.LANCZOS)  # symbol has 1.25x scale headroom
    canvas.alpha_composite(sym, ((W - 420) // 2, 0))
    font = ImageFont.truetype(FONT, 150)
    d = ImageDraw.Draw(canvas)
    text = "CineTrack"
    l, t, r, b = d.textbbox((0, 0), text, font=font)
    d.text(((W - (r - l)) / 2 - l, 520 - t), text, font=font, fill=(255, 255, 255, 255))
    h = round(width * H / W)
    return canvas.resize((width, h), Image.LANCZOS)


make_splash_logo(675).save("assets/splash_logo.png")  # in-app (3x of 225 logical px)
os.makedirs("web/splash", exist_ok=True)
make_splash_logo(675).save("web/splash/logo.png")

# Android: xxhdpi bucket (480dpi) so 675px renders at 225dp on every density
os.makedirs("android/app/src/main/res/drawable-xxhdpi", exist_ok=True)
make_splash_logo(675).save("android/app/src/main/res/drawable-xxhdpi/splash_logo.png")

# iOS LaunchImage 1x/2x/3x = 225/450/675 px wide
for name, w in {"LaunchImage.png": 225, "LaunchImage@2x.png": 450, "LaunchImage@3x.png": 675}.items():
    make_splash_logo(w).save("ios/Runner/Assets.xcassets/LaunchImage.imageset/" + name)
