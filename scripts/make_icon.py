"""Builds Assets/AppIcon-1024.png (blue tile, white arrows) from the approved v2 arrow shapes."""
import sys
from pathlib import Path
import numpy as np
from scipy import ndimage
from PIL import Image, ImageDraw, ImageFilter

root = Path(__file__).resolve().parent.parent
src = np.array(Image.open(root / "Assets/logo-v2-speed-arrows.png").convert("RGBA")).astype(np.float32)

# Arrow coverage from the source's blue saturation; tile bounds measured from its alpha.
tile_box = (128, 136, 1124, 1112)
r, g, b, a = (src[..., i] for i in range(4))
coverage = np.clip((b - r - 25) / 90, 0, 1) * (a / 255)
x0, y0, x1, y1 = tile_box
arrows = Image.fromarray((coverage[y0:y1, x0:x1] * 255).astype(np.uint8), "L")

S, T, O = 1024, 824, 100  # canvas, tile size, tile origin (macOS icon grid)
arrows = arrows.resize((T, T), Image.LANCZOS)
mask = Image.new("L", (S, S), 0)
mask.paste(arrows, (O, O))

labels, _ = ndimage.label(np.array(mask) > 40)
upper = labels[O + int(T * 0.3), O + int(T * 0.6)]
near_upper = ndimage.binary_dilation(labels == upper, iterations=3)
top_arrow = Image.fromarray((np.array(mask) * near_upper).astype(np.uint8))

tile = Image.new("L", (S, S), 0)
ImageDraw.Draw(tile).rounded_rectangle((O, O, O + T - 1, O + T - 1), radius=185, fill=255)
tile = tile.filter(ImageFilter.GaussianBlur(0.6))

yy = np.linspace(0, 1, S)[:, None]
grad = np.zeros((S, S, 4), np.float32)
top, bottom = np.array([56, 160, 255]), np.array([12, 72, 214])
grad[..., :3] = top * (1 - yy[..., None]) + bottom * yy[..., None]
grad[..., 3] = 255
canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow.paste((0, 0, 0, 90), (0, 0), tile.filter(ImageFilter.GaussianBlur(14)).transform((S, S), Image.AFFINE, (1, 0, 0, 0, 1, -10)))
canvas = Image.alpha_composite(canvas, shadow)

body = Image.fromarray(grad.astype(np.uint8), "RGBA")
body.putalpha(tile)
canvas = Image.alpha_composite(canvas, body)

sheen = Image.new("L", (S, S), 0)
ImageDraw.Draw(sheen).ellipse((O - 200, O - 520, O + T + 200, O + T * 0.42), fill=34)
sheen = Image.fromarray(np.minimum(np.array(sheen.filter(ImageFilter.GaussianBlur(40))), np.array(tile)))
canvas = Image.alpha_composite(canvas, Image.merge("RGBA", (*[Image.new("L", (S, S), 255)] * 3, sheen)))

arrow_shadow = mask.filter(ImageFilter.GaussianBlur(10)).point(lambda v: v * 0.35)
arrow_shadow = arrow_shadow.transform((S, S), Image.AFFINE, (1, 0, 0, 0, 1, -8))
canvas = Image.alpha_composite(canvas, Image.merge("RGBA", (*[Image.new("L", (S, S), 0)] * 3, arrow_shadow)))

bottom_arrow = Image.fromarray(np.clip(np.array(mask, np.int16) - np.array(top_arrow, np.int16), 0, 255).astype(np.uint8))
canvas = Image.alpha_composite(canvas, Image.merge("RGBA", (*[Image.new("L", (S, S), 255)] * 3, top_arrow)))
canvas = Image.alpha_composite(canvas, Image.merge("RGBA", (Image.new("L", (S, S), 214), Image.new("L", (S, S), 236), Image.new("L", (S, S), 255), bottom_arrow)))

out = root / (sys.argv[1] if len(sys.argv) > 1 else "Assets/AppIcon-1024.png")
canvas.save(out)
print(out)
