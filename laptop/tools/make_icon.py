"""Draws the PhoneCam icon (phone with a camera lens) and saves it as .ico."""

import sys

from PIL import Image, ImageDraw


def draw(size: int = 256) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    s = size / 256
    d.rounded_rectangle((16 * s, 16 * s, 240 * s, 240 * s), radius=52 * s, fill=(17, 19, 21, 255))
    d.rounded_rectangle((82 * s, 44 * s, 174 * s, 212 * s), radius=18 * s, fill=(61, 220, 151, 255))
    d.rounded_rectangle((92 * s, 58 * s, 164 * s, 186 * s), radius=8 * s, fill=(17, 19, 21, 255))
    d.ellipse((104 * s, 98 * s, 152 * s, 146 * s), fill=(61, 220, 151, 255))
    d.ellipse((117 * s, 111 * s, 139 * s, 133 * s), fill=(17, 19, 21, 255))
    d.ellipse((122 * s, 193 * s, 134 * s, 205 * s), fill=(17, 19, 21, 255))
    return img


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "phonecam.ico"
    draw().save(out, sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print(f"wrote {out}")
