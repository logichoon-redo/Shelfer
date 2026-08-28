#!/usr/bin/env python3
"""Generate the Shelfer app icon: a floating shelf holding a stack of files."""

import io
import math
import os
from PIL import Image, ImageFilter

import cairosvg

S = 1024  # master canvas


# ---------------------------------------------------------------- squircle

def squircle_path(x0=100.0, y0=100.0, side=824.0, r=186.0, n=5.0, steps=96):
    """Straight edges joined by Apple-style continuous (superelliptical) corners."""
    x1, y1 = x0 + side, y0 + side
    e = 2.0 / n

    def corner(cx, cy, a0, a1):
        pts = []
        for i in range(steps + 1):
            t = math.radians(a0 + (a1 - a0) * i / steps)
            c, sn = math.cos(t), math.sin(t)
            pts.append((
                cx + r * math.copysign(abs(c) ** e, c),
                cy + r * math.copysign(abs(sn) ** e, sn),
            ))
        return pts

    path = [(x0 + r, y0)]
    path += corner(x1 - r, y0 + r, -90, 0)      # top-right
    path += corner(x1 - r, y1 - r, 0, 90)       # bottom-right
    path += corner(x0 + r, y1 - r, 90, 180)     # bottom-left
    path += corner(x0 + r, y0 + r, 180, 270)    # top-left
    return "M" + "L".join(f"{x:.2f},{y:.2f}" for x, y in path) + "Z"


SQUIRCLE = squircle_path()


# ---------------------------------------------------------------- geometry

class Art:
    """One composition. `small` trades fine detail for legibility at 16-32px."""

    def __init__(self, small=False):
        self.small = small
        if small:
            self.shelf = dict(x=176, y=640, w=672, h=84, rx=24)
            self.front = dict(x=388, y=296, w=248, h=344, rx=36)
            self.card_w, self.card_h, self.card_rx = 226, 310, 34
            self.left_anchor, self.left_rot = (378, 644), -10
            self.right_anchor, self.right_rot = (646, 644), 9
        else:
            self.shelf = dict(x=190, y=648, w=644, h=68, rx=18)
            self.front = dict(x=396, y=316, w=232, h=332, rx=30)
            self.card_w, self.card_h, self.card_rx = 214, 300, 28
            self.left_anchor, self.left_rot = (388, 650), -11
            self.right_anchor, self.right_rot = (636, 650), 9

    def _card(self, anchor, rot, fill):
        """A card standing on `anchor` (its bottom-centre), tipped by `rot`."""
        x = anchor[0] - self.card_w / 2
        y = anchor[1] - self.card_h
        return (
            f'<g transform="rotate({rot} {anchor[0]} {anchor[1]})">'
            f'<rect x="{x}" y="{y}" width="{self.card_w}" height="{self.card_h}" '
            f'rx="{self.card_rx}" ry="{self.card_rx}" fill="{fill}"/></g>'
        )

    def cards(self, left_fill, right_fill, front_fill):
        f = self.front
        return (
            self._card(self.left_anchor, self.left_rot, left_fill)
            + self._card(self.right_anchor, self.right_rot, right_fill)
            + f'<rect x="{f["x"]}" y="{f["y"]}" width="{f["w"]}" height="{f["h"]}" '
              f'rx="{f["rx"]}" ry="{f["rx"]}" fill="{front_fill}"/>'
        )

    def shelf_rect(self, fill):
        s = self.shelf
        return (
            f'<rect x="{s["x"]}" y="{s["y"]}" width="{s["w"]}" height="{s["h"]}" '
            f'rx="{s["rx"]}" ry="{s["rx"]}" fill="{fill}"/>'
        )


def svg(body, defs=""):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" '
        f'viewBox="0 0 {S} {S}"><defs>{defs}</defs>{body}</svg>'
    )


def render(markup):
    png = cairosvg.svg2png(bytestring=markup.encode(), output_width=S, output_height=S)
    return Image.open(io.BytesIO(png)).convert("RGBA")


# ---------------------------------------------------------------- palette

BG_DEFS = """
<linearGradient id="bg" x1="0.12" y1="0" x2="0.88" y2="1">
  <stop offset="0"    stop-color="#78A4FF"/>
  <stop offset="0.42" stop-color="#3A66EC"/>
  <stop offset="1"    stop-color="#15277E"/>
</linearGradient>
<radialGradient id="glow" cx="0.5" cy="0.16" r="0.72">
  <stop offset="0"   stop-color="#FFFFFF" stop-opacity="0.22"/>
  <stop offset="1"   stop-color="#FFFFFF" stop-opacity="0"/>
</radialGradient>
<linearGradient id="amber" x1="0" y1="0" x2="0.4" y2="1">
  <stop offset="0" stop-color="#FFDD97"/><stop offset="1" stop-color="#F0A63E"/>
</linearGradient>
<linearGradient id="mint" x1="0" y1="0" x2="0.4" y2="1">
  <stop offset="0" stop-color="#A9F1DC"/><stop offset="1" stop-color="#45C6AE"/>
</linearGradient>
<linearGradient id="paper" x1="0.2" y1="0" x2="0.6" y2="1">
  <stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#E2EBFF"/>
</linearGradient>
<linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0"    stop-color="#FFFFFF" stop-opacity="0.42"/>
  <stop offset="0.45" stop-color="#FFFFFF" stop-opacity="0.06"/>
  <stop offset="1"    stop-color="#FFFFFF" stop-opacity="0"/>
</linearGradient>
<linearGradient id="plank" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0"    stop-color="#FFFFFF"/>
  <stop offset="0.55" stop-color="#F3F7FF"/>
  <stop offset="1"    stop-color="#BFD1F2"/>
</linearGradient>
"""


def build(small=False):
    art = Art(small=small)

    mask = render(svg(f'<path d="{SQUIRCLE}" fill="#FFFFFF"/>')).getchannel("A")

    background = render(svg(
        f'<path d="{SQUIRCLE}" fill="url(#bg)"/>'
        + ("" if small else f'<path d="{SQUIRCLE}" fill="url(#glow)"/>'),
        BG_DEFS,
    ))

    card_shadow = render(svg(art.cards("#00113A", "#00113A", "#00113A")))
    shelf_shadow = render(svg(art.shelf_rect("#00113A")))

    cards = render(svg(
        art.cards("url(#amber)", "url(#mint)", "url(#paper)"), BG_DEFS))
    shelf = render(svg(art.shelf_rect("url(#plank)"), BG_DEFS))

    def soft(layer, blur, dy, alpha):
        out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        out.paste(layer, (0, dy))
        out = out.filter(ImageFilter.GaussianBlur(blur))
        a = out.getchannel("A").point(lambda v: int(v * alpha))
        out.putalpha(a)
        return out

    rim = render(svg(
        f'<path d="{SQUIRCLE}" fill="none" stroke="url(#rim)" stroke-width="5"/>',
        BG_DEFS))

    contact = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    contact.paste(
        soft(card_shadow, 14 if not small else 10, 30, 0.34),
        (0, 0), shelf.getchannel("A"),
    )

    canvas = background
    for layer in (
        soft(card_shadow, 26 if not small else 18, 20, 0.45),
        cards,
        soft(shelf_shadow, 30 if not small else 20, 26, 0.55),
        shelf,
        contact,
        rim,
    ):
        canvas = Image.alpha_composite(canvas, layer)

    # Clip any shadow spill back to the icon silhouette.
    clipped = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    clipped.paste(canvas, (0, 0), mask)
    return clipped


# ---------------------------------------------------------------- output

MAC_SIZES = [
    (16, "1x"), (16, "2x"), (32, "1x"), (32, "2x"), (128, "1x"),
    (128, "2x"), (256, "1x"), (256, "2x"), (512, "1x"), (512, "2x"),
]

SMALL_THRESHOLD = 48  # below this, use the simplified composition


def main():
    out_dir = os.environ.get("ICON_OUT", ".")
    os.makedirs(out_dir, exist_ok=True)

    master = build(small=False)
    master_small = build(small=True)

    master.save(os.path.join(out_dir, "Shelfer-1024.png"))

    images = []
    for pt, scale in MAC_SIZES:
        px = pt * (2 if scale == "2x" else 1)
        source = master if px >= SMALL_THRESHOLD else master_small
        name = f"icon_{pt}x{pt}{'@2x' if scale == '2x' else ''}.png"
        source.resize((px, px), Image.LANCZOS).save(os.path.join(out_dir, name))
        images.append({
            "filename": name, "idiom": "mac",
            "scale": scale, "size": f"{pt}x{pt}",
        })

    import json
    with open(os.path.join(out_dir, "Contents.json"), "w") as fh:
        json.dump(
            {"images": images, "info": {"author": "xcode", "version": 1}},
            fh, indent=2,
        )
        fh.write("\n")

    print("wrote", len(images), "png +", "Contents.json ->", out_dir)


if __name__ == "__main__":
    main()
