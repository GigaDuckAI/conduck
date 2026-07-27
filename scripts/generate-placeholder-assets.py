#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

"""Generate the neutral placeholder assets this repository ships in its catalogs.

The asset catalogs contain neutral stand-in art; the official App Store build
overlays proprietary brand art (not part of this repository) at build time.
This script regenerates the stand-ins into branding/placeholders/, mirroring
the catalog paths — the staged sets and the catalogs must stay byte-identical.

For every art-bearing set (all imagesets/appiconsets except colorsets; the
empty ConduckWatch AppIcon is skipped automatically because it has no image
files) it emits:
  - an IDENTICAL Contents.json (verbatim byte copy of the original), and
  - placeholder images with the SAME filenames and SAME pixel dimensions.

Visual language (nothing derivative of the proprietary brand art):
  - imagesets: flat light-neutral rounded tile (#E9EAEE, ~18% corner radius)
    with a centered chat-bubble outline glyph in slate (#4A5568), RGBA.
  - appiconsets: full-bleed flat #5B6B7A square (no rounded corners baked in)
    with a white filled chat-bubble glyph, RGB.
  - menubar-conduck: monochrome black-on-transparent bubble glyph, emitted as a
    hand-written vector PDF (the original is an 18x18pt template PDF).
  - discord-logo: same generic bubble tile treatment (the third-party mark is
    not redistributed here).

Deterministic and re-runnable: no timestamps, no randomness — identical output
bytes on every run. Requires python3 + Pillow.

Usage:  python3 scripts/generate-placeholder-assets.py
"""

import json
import shutil
import sys
from pathlib import Path

try:
    from PIL import Image, ImageChops, ImageDraw
except ImportError:
    sys.exit("Pillow is required: python3 -m pip install --user Pillow")

REPO_ROOT = Path(__file__).resolve().parents[1]
PROJECT_DIR = REPO_ROOT / "Conduck"                      # dir beside Conduck.xcodeproj
OUT_ROOT = REPO_ROOT / "branding" / "placeholders"

# Catalogs, relative to PROJECT_DIR (mirrored verbatim under OUT_ROOT).
CATALOGS = [
    "Conduck/Assets.xcassets",
    "ConduckWatch Watch App/Assets.xcassets",
    "ConduckWatch/Assets.xcassets",
    "ConduckShareExtensionMac/Assets.xcassets",
]

TILE_BG = (0xE9, 0xEA, 0xEE, 0xFF)      # light neutral
GLYPH_SLATE = (0x4A, 0x55, 0x68, 0xFF)  # slate
ICON_BG = (0x5B, 0x6B, 0x7A)            # app-icon background
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".pdf", ".svg", ".heic"}


# --- chat-bubble geometry -----------------------------------------------------

def bubble_mask(w, h):
    """Filled chat-bubble (rounded body + lower-left tail) as an L-mask of w×h.

    Drawn in a normalized box: body fills the top ~78%% of the height, tail
    drops from the body's lower-left toward the bottom-left corner.
    """
    m = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(m)
    body_h = h * 0.78
    r = min(w, body_h) * 0.28
    d.rounded_rectangle([0, 0, w - 1, body_h], radius=r, fill=255)
    # Tail: triangle overlapping the body's bottom edge.
    d.polygon(
        [
            (w * 0.20, body_h * 0.90),
            (w * 0.44, body_h * 0.90),
            (w * 0.14, h - 1),
        ],
        fill=255,
    )
    return m


def bubble_outline_mask(w, h, stroke):
    """Outline-only bubble mask: filled bubble minus an inset filled bubble."""
    outer = bubble_mask(w, h)
    iw, ih = max(1, w - 2 * stroke), max(1, h - 2 * stroke)
    inner_small = bubble_mask(iw, ih)
    inner = Image.new("L", (w, h), 0)
    inner.paste(inner_small, (stroke, stroke))
    return ImageChops.subtract(outer, inner)


# --- renderers ----------------------------------------------------------------

def supersample_factor(w, h):
    s = max(4, 256 // max(1, min(w, h)))
    return min(s, 16)


def render_tile(w, h):
    """Light-neutral rounded tile + slate bubble outline. RGBA."""
    s = supersample_factor(w, h)
    W, H = w * s, h * s
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    radius = int(min(W, H) * 0.18)
    d.rounded_rectangle([0, 0, W - 1, H - 1], radius=radius, fill=TILE_BG)
    gw = int(min(W, H) * 0.52)
    gh = int(gw * 0.92)
    stroke = max(s, int(gw * 0.07))
    ring = bubble_outline_mask(gw, gh, stroke)
    glyph = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    glyph.paste(Image.new("RGBA", (gw, gh), GLYPH_SLATE), ((W - gw) // 2, (H - gh) // 2), ring)
    img = Image.alpha_composite(img, glyph)
    return img.resize((w, h), Image.LANCZOS)


def render_appicon(w, h):
    """Full-bleed flat square + white filled bubble. RGB (no alpha)."""
    s = supersample_factor(w, h)
    W, H = w * s, h * s
    img = Image.new("RGB", (W, H), ICON_BG)
    gw = int(min(W, H) * 0.54)
    gh = int(gw * 0.92)
    mask = bubble_mask(gw, gh)
    img.paste((255, 255, 255), ((W - gw) // 2, (H - gh) // 2), mask)
    return img.resize((w, h), Image.LANCZOS)


def render_menubar_png(w, h):
    """Monochrome black-on-transparent bubble outline (template image). RGBA."""
    s = supersample_factor(w, h)
    W, H = w * s, h * s
    gw = int(min(W, H) * 0.94)
    gh = int(gw * 0.96)
    stroke = max(s, int(gw * 0.09))
    ring = bubble_outline_mask(gw, gh, stroke)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    img.paste(Image.new("RGBA", (gw, gh), (0, 0, 0, 255)), ((W - gw) // 2, (H - gh) // 2), ring)
    return img.resize((w, h), Image.LANCZOS)


# --- menubar template PDF (hand-written, deterministic) -----------------------

def menubar_pdf_bytes(pt_w, pt_h):
    """Minimal vector PDF: black stroked bubble on transparent background.

    Unpainted areas of a PDF page are transparent, which is exactly what a
    macOS template (monochrome + alpha) menubar image needs.
    """
    k = 0.5523  # bezier circle constant
    # Body rounded rect in page coords (PDF origin = bottom-left).
    x0, x1 = pt_w * 0.06, pt_w * 0.94
    y0, y1 = pt_h * 0.28, pt_h * 0.94
    r = min(x1 - x0, y1 - y0) * 0.30
    sw = pt_w * 0.085

    def f(v):
        return f"{v:.3f}"

    ops = []
    ops.append(f"{f(sw)} w 1 j 1 J 0 G 0 g")
    # Rounded-rect path (clockwise from lower-left arc end).
    ops.append(f"{f(x0 + r)} {f(y0)} m")
    ops.append(f"{f(x1 - r)} {f(y0)} l")
    ops.append(f"{f(x1 - r + r * k)} {f(y0)} {f(x1)} {f(y0 + r - r * k)} {f(x1)} {f(y0 + r)} c")
    ops.append(f"{f(x1)} {f(y1 - r)} l")
    ops.append(f"{f(x1)} {f(y1 - r + r * k)} {f(x1 - r + r * k)} {f(y1)} {f(x1 - r)} {f(y1)} c")
    ops.append(f"{f(x0 + r)} {f(y1)} l")
    ops.append(f"{f(x0 + r - r * k)} {f(y1)} {f(x0)} {f(y1 - r + r * k)} {f(x0)} {f(y1 - r)} c")
    ops.append(f"{f(x0)} {f(y0 + r)} l")
    ops.append(f"{f(x0)} {f(y0 + r - r * k)} {f(x0 + r - r * k)} {f(y0)} {f(x0 + r)} {f(y0)} c")
    ops.append("s")  # close + stroke
    # Tail: filled triangle from the body's bottom edge to the lower-left.
    tx0, tx1 = pt_w * 0.22, pt_w * 0.46
    ty = y0 + sw * 0.4
    ops.append(f"{f(tx0)} {f(ty)} m {f(tx1)} {f(ty)} l {f(pt_w * 0.16)} {f(pt_h * 0.04)} l h f")
    stream = ("\n".join(ops) + "\n").encode("ascii")

    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        f"<< /Type /Pages /Kids [3 0 R] /Count 1 >>".encode("ascii"),
        f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {pt_w:g} {pt_h:g}] /Contents 4 0 R >>".encode("ascii"),
        b"<< /Length " + str(len(stream)).encode("ascii") + b" >>\nstream\n" + stream + b"endstream",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, body in enumerate(objs, start=1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode("ascii") + body + b"\nendobj\n"
    xref_pos = len(out)
    out += f"xref\n0 {len(objs) + 1}\n".encode("ascii")
    out += b"0000000000 65535 f \n"
    for off in offsets:
        out += f"{off:010d} 00000 n \n".encode("ascii")
    out += (
        f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{xref_pos}\n%%EOF\n"
    ).encode("ascii")
    return bytes(out)


# --- driver -------------------------------------------------------------------

def source_dimensions(path):
    """Pixel dimensions of an original asset image (PDF → point size)."""
    if path.suffix.lower() == ".pdf":
        data = path.read_bytes()
        # Parse the first /MediaBox [a b c d].
        idx = data.find(b"/MediaBox")
        box = data[idx:idx + 120].split(b"[", 1)[1].split(b"]", 1)[0].split()
        a, b, c, d = (float(v) for v in box)
        return int(round(c - a)), int(round(d - b))
    with Image.open(path) as im:
        return im.size


def main():
    if OUT_ROOT.exists():
        shutil.rmtree(OUT_ROOT)
    emitted_sets = 0
    emitted_images = 0
    for cat_rel in CATALOGS:
        cat_dir = PROJECT_DIR / cat_rel
        for set_dir in sorted(cat_dir.iterdir()):
            if not set_dir.is_dir():
                continue
            kind = set_dir.suffix  # .imageset / .appiconset / .colorset
            if kind == ".colorset":
                continue  # color values are safe to publish — no placeholder
            images = sorted(
                p for p in set_dir.iterdir()
                if p.is_file() and p.suffix.lower() in IMAGE_EXTS
            )
            if not images:
                continue  # e.g. the empty ConduckWatch AppIcon (Contents.json only)
            contents = set_dir / "Contents.json"
            json.loads(contents.read_text())  # sanity: must parse
            out_set = OUT_ROOT / cat_rel / set_dir.name
            out_set.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(contents, out_set / "Contents.json")
            for src in images:
                w, h = source_dimensions(src)
                dst = out_set / src.name
                if set_dir.name == "menubar-conduck.imageset":
                    if src.suffix.lower() == ".pdf":
                        dst.write_bytes(menubar_pdf_bytes(w, h))
                    else:
                        render_menubar_png(w, h).save(dst, format="PNG")
                elif kind == ".appiconset":
                    render_appicon(w, h).save(dst, format="PNG")
                else:
                    render_tile(w, h).save(dst, format="PNG")
                emitted_images += 1
            emitted_sets += 1
            print(f"  {cat_rel}/{set_dir.name}  ({len(images)} file(s))")
    print(f"Done: {emitted_sets} sets, {emitted_images} images → {OUT_ROOT}")


if __name__ == "__main__":
    main()
