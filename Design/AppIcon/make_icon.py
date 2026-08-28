#!/usr/bin/env python3
"""Shelfer app icon: the shelf panel itself, with a cursor setting a file down.

Abstracted to four shapes — the panel, its grab handle, one file, one pointer.
Colours are taken from the running app: the panel's deep teal and the pale
mint of its label pill.
"""

import io
import math
import os
from PIL import Image, ImageFilter

import cairosvg

S = 1024


# ---------------------------------------------------------------- silhouette

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
    path += corner(x1 - r, y0 + r, -90, 0)
    path += corner(x1 - r, y1 - r, 0, 90)
    path += corner(x0 + r, y1 - r, 90, 180)
    path += corner(x0 + r, y0 + r, 180, 270)
    return "M" + "L".join(f"{x:.2f},{y:.2f}" for x, y in path) + "Z"


SQUIRCLE = squircle_path()


# ---------------------------------------------------------------- shapes

def document(x0, y0, w, h, r, cut):
    """A page with one folded corner — the whole of what says 'file' here."""
    x1, y1 = x0 + w, y0 + h
    page = (
        f"M{x0 + r},{y0} L{x1 - cut},{y0} L{x1},{y0 + cut} L{x1},{y1 - r} "
        f"Q{x1},{y1} {x1 - r},{y1} L{x0 + r},{y1} Q{x0},{y1} {x0},{y1 - r} "
        f"L{x0},{y0 + r} Q{x0},{y0} {x0 + r},{y0} Z"
    )
    flap = f"M{x1 - cut},{y0} L{x1},{y0 + cut} L{x1 - cut},{y0 + cut} Z"
    return page, flap


# Classic pointer silhouette, tip at the origin, in a 92 x 138 box.
POINTER = ("M0,0 L0,116 L30,88 L52,138 L76,128 L54,80 L92,78 Z")


class Art:
    """`small` drops the details that turn to mud below 48px."""

    def __init__(self, small=False):
        self.small = small
        if small:
            self.handle = None
            self.doc = dict(x=340, y=306, w=330, h=420, r=30, cut=110)
            self.doc_rot = -10
            self.ptr = dict(x=302, y=320, k=1.54, stroke=10)
        else:
            self.handle = dict(x=437, y=188, w=150, h=20, rx=10)
            self.doc = dict(x=352, y=318, w=306, h=390, r=26, cut=96)
            self.doc_rot = -10
            self.ptr = dict(x=316, y=330, k=1.38, stroke=8)

    @property
    def doc_pivot(self):
        d = self.doc
        return d["x"] + d["w"] / 2, d["y"] + d["h"] / 2

    def doc_group(self, page_fill, flap_fill):
        d = self.doc
        page, flap = document(d["x"], d["y"], d["w"], d["h"], d["r"], d["cut"])
        cx, cy = self.doc_pivot
        return (
            f'<g transform="rotate({self.doc_rot} {cx} {cy})">'
            f'<path d="{page}" fill="{page_fill}"/>'
            f'<path d="{flap}" fill="{flap_fill}"/></g>'
        )

    def doc_silhouette(self, fill):
        d = self.doc
        page, _ = document(d["x"], d["y"], d["w"], d["h"], d["r"], d["cut"])
        cx, cy = self.doc_pivot
        return (f'<g transform="rotate({self.doc_rot} {cx} {cy})">'
                f'<path d="{page}" fill="{fill}"/></g>')

    def pointer(self, fill, stroke=None):
        p = self.ptr
        edge = (f' stroke="{stroke}" stroke-width="{p["stroke"]}" '
                f'stroke-linejoin="round"' if stroke else "")
        return (
            f'<g transform="translate({p["x"]} {p["y"]}) scale({p["k"]})">'
            f'<path d="{POINTER}" fill="{fill}"{edge}/></g>'
        )


def svg(body, defs=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" '
            f'viewBox="0 0 {S} {S}"><defs>{defs}</defs>{body}</svg>')


def render(markup):
    png = cairosvg.svg2png(bytestring=markup.encode(), output_width=S, output_height=S)
    return Image.open(io.BytesIO(png)).convert("RGBA")


# ---------------------------------------------------------------- palette

PANEL_DEEP = "#16302B"

DEFS = """
<linearGradient id="panel" x1="0.15" y1="0" x2="0.85" y2="1">
  <stop offset="0"    stop-color="#4E7A6C"/>
  <stop offset="0.48" stop-color="#2E524A"/>
  <stop offset="1"    stop-color="#16302B"/>
</linearGradient>
<radialGradient id="glow" cx="0.5" cy="0.14" r="0.74">
  <stop offset="0" stop-color="#B8E5D2" stop-opacity="0.20"/>
  <stop offset="1" stop-color="#B8E5D2" stop-opacity="0"/>
</radialGradient>
<linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0"    stop-color="#FFFFFF" stop-opacity="0.34"/>
  <stop offset="0.45" stop-color="#FFFFFF" stop-opacity="0.05"/>
  <stop offset="1"    stop-color="#FFFFFF" stop-opacity="0"/>
</linearGradient>
<linearGradient id="page" x1="0.1" y1="0" x2="0.6" y2="1">
  <stop offset="0" stop-color="#FFFFFF"/>
  <stop offset="1" stop-color="#C9E2D6"/>
</linearGradient>
"""


def build(small=False):
    art = Art(small=small)

    mask = render(svg(f'<path d="{SQUIRCLE}" fill="#FFFFFF"/>')).getchannel("A")

    ground = render(svg(
        f'<path d="{SQUIRCLE}" fill="url(#panel)"/>'
        + ("" if small else f'<path d="{SQUIRCLE}" fill="url(#glow)"/>'),
        DEFS,
    ))

    handle = None
    if art.handle:
        h = art.handle
        handle = render(svg(
            f'<rect x="{h["x"]}" y="{h["y"]}" width="{h["w"]}" height="{h["h"]}" '
            f'rx="{h["rx"]}" ry="{h["rx"]}" fill="#FFFFFF" fill-opacity="0.34"/>'))

    doc_shadow = render(svg(art.doc_silhouette("#06201B")))
    doc = render(svg(art.doc_group("url(#page)", "#8FB6A6"), DEFS))

    ptr_shadow = render(svg(art.pointer("#06201B", "#06201B")))
    pointer = render(svg(art.pointer("#FFFFFF", PANEL_DEEP)))

    rim = render(svg(
        f'<path d="{SQUIRCLE}" fill="none" stroke="url(#rim)" stroke-width="5"/>',
        DEFS))

    def soft(layer, blur, dy, alpha):
        out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        out.paste(layer, (0, dy))
        out = out.filter(ImageFilter.GaussianBlur(blur))
        out.putalpha(out.getchannel("A").point(lambda v: int(v * alpha)))
        return out

    layers = [
        soft(doc_shadow, 30 if not small else 22, 24, 0.46),
        doc,
        soft(ptr_shadow, 16 if not small else 12, 14, 0.38),
        pointer,
    ]
    if handle is not None:
        layers.insert(0, handle)
    if not small:
        layers.append(rim)

    canvas = ground
    for layer in layers:
        canvas = Image.alpha_composite(canvas, layer)

    clipped = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    clipped.paste(canvas, (0, 0), mask)
    return clipped


# ---------------------------------------------------------------- output

MAC_SIZES = [
    (16, "1x"), (16, "2x"), (32, "1x"), (32, "2x"), (128, "1x"),
    (128, "2x"), (256, "1x"), (256, "2x"), (512, "1x"), (512, "2x"),
]

SMALL_THRESHOLD = 48


def main():
    import json

    out_dir = os.environ.get("ICON_OUT", ".")
    os.makedirs(out_dir, exist_ok=True)

    master, master_small = build(False), build(True)
    master.save(os.path.join(out_dir, "Shelfer-1024.png"))

    images = []
    for pt, scale in MAC_SIZES:
        px = pt * (2 if scale == "2x" else 1)
        source = master if px >= SMALL_THRESHOLD else master_small
        name = f"icon_{pt}x{pt}{'@2x' if scale == '2x' else ''}.png"
        source.resize((px, px), Image.LANCZOS).save(os.path.join(out_dir, name))
        images.append({"filename": name, "idiom": "mac",
                       "scale": scale, "size": f"{pt}x{pt}"})

    with open(os.path.join(out_dir, "Contents.json"), "w") as fh:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}},
                  fh, indent=2)
        fh.write("\n")

    print("wrote", len(images), "png + Contents.json ->", out_dir)


if __name__ == "__main__":
    main()
