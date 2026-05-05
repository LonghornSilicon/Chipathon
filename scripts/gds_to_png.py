#!/usr/bin/env python3
"""
Render a GDS layout to a polished PNG using KLayout in batch mode.

Run via the KLayout binary so the `pya` module is in scope:

    klayout -b -r scripts/gds_to_png.py \
        -rd gds=pd/mac_array_4x4/runs/<tag>/final/gds/mac_array_4x4.gds \
        -rd png=pd/mac_array_4x4/gds/mac_array_4x4.png

Optional `-rd` overrides:
    lyp=<path>       Layer-properties file (defaults to the sky130A .lyp shipped
                     with the active PDK).
    long_side=<int>  Longest output side in pixels (default 4096). The other
                     dimension is computed from the cell's bounding box so the
                     image is never distorted and never wastes background.
    width=<int>      Force exact image width (overrides long_side / aspect).
    height=<int>     Force exact image height (overrides long_side / aspect).
    cell=<name>      Top cell to render (default = first top cell).
    bg=<#rrggbb>     Background colour (default #0d1117 — dark slate).
    margin=<float>   Extra padding around the cell as a fraction of bbox (0.04).
    oversample=<1-3> Anti-alias supersampling factor (default 3 = best quality).

Prefer the wrapper `scripts/gds_to_png.sh` for the common case — it
auto-discovers the most recent OpenLane run and supplies the PDK .lyp.
"""

from __future__ import annotations

import os
import sys

import pya  # type: ignore[import-not-found]


def _arg(name: str, default: str | None = None) -> str | None:
    value = globals().get(name, default)
    if value is None or value == "":
        return default
    return str(value)


def main() -> int:
    gds_path = _arg("gds")
    if not gds_path:
        sys.stderr.write("ERROR: pass -rd gds=<path/to/file.gds>\n")
        return 1
    if not os.path.isfile(gds_path):
        sys.stderr.write(f"ERROR: gds not found: {gds_path}\n")
        return 1

    png_path = _arg("png", os.path.splitext(gds_path)[0] + ".png")

    pdk_root = os.environ.get("PDK_ROOT", os.path.expanduser("~/.volare"))
    pdk = os.environ.get("PDK", "sky130A")
    default_lyp = os.path.join(
        pdk_root, pdk, "libs.tech", "klayout", "tech", f"{pdk}.lyp"
    )
    lyp_path = _arg("lyp", default_lyp if os.path.isfile(default_lyp) else None)

    long_side = int(_arg("long_side", "4096"))
    forced_w = _arg("width")
    forced_h = _arg("height")
    bg_colour = _arg("bg", "#0d1117")
    margin = float(_arg("margin", "0.04"))
    oversample = max(1, min(3, int(_arg("oversample", "3"))))

    layout = pya.Layout()
    layout.read(gds_path)

    requested_cell = _arg("cell")
    if requested_cell:
        cell = layout.cell(requested_cell)
        if cell is None:
            sys.stderr.write(f"ERROR: cell '{requested_cell}' not found.\n")
            return 1
    else:
        tops = layout.top_cells()
        if not tops:
            sys.stderr.write("ERROR: layout has no top cells.\n")
            return 1
        cell = tops[0]

    bbox = cell.dbbox()
    if bbox.empty():
        sys.stderr.write("ERROR: top cell bbox is empty.\n")
        return 1

    aspect = bbox.width() / bbox.height()
    if forced_w and forced_h:
        width, height = int(forced_w), int(forced_h)
    elif aspect >= 1.0:
        width = long_side
        height = max(1, int(round(long_side / aspect)))
    else:
        height = long_side
        width = max(1, int(round(long_side * aspect)))

    print(f"[gds_to_png] input      : {gds_path}")
    print(f"[gds_to_png] output     : {png_path}")
    print(f"[gds_to_png] top cell   : {cell.name}")
    print(f"[gds_to_png] bbox (um)  : {bbox.width():.2f} x {bbox.height():.2f}")
    print(
        f"[gds_to_png] image (px) : {width} x {height} (aspect-fit, "
        f"oversample x{oversample})"
    )
    print(f"[gds_to_png] layers     : {lyp_path or '(default klayout palette)'}")

    view = pya.LayoutView()
    view.show_layout(layout, False)
    if lyp_path and os.path.isfile(lyp_path):
        view.load_layer_props(lyp_path)

    # ---- Polished display settings ----
    view.set_config("background-color",       bg_colour)
    view.set_config("grid-visible",           "false")
    view.set_config("grid-show-ruler",        "false")
    view.set_config("text-visible",           "false")
    view.set_config("cell-box-visible",       "false")
    view.set_config("cell-text-visible",      "false")
    view.set_config("guiding-shapes-visible", "false")
    view.set_config("default-text-size",      "0")
    view.set_config("draw-array-border-instances", "false")
    view.set_config("draw-cell-frame",        "false")

    view.max_hier()

    # Pad the cell bbox so layout doesn't kiss the image edges.
    pad_x = bbox.width()  * margin
    pad_y = bbox.height() * margin
    target = pya.DBox(
        bbox.left  - pad_x, bbox.bottom - pad_y,
        bbox.right + pad_x, bbox.top    + pad_y,
    )
    view.zoom_box(target)

    os.makedirs(os.path.dirname(os.path.abspath(png_path)) or ".", exist_ok=True)

    # save_image_with_options(filename, w, h, linewidth, oversampling,
    #                         resolution, target_box, monochrome)
    view.save_image_with_options(
        png_path,
        width, height,
        0,                  # linewidth = auto
        oversample,         # supersampling for clean antialiased edges
        0,                  # resolution = auto
        target,             # explicit target box (no further auto-fit)
        False,              # not monochrome
    )
    print(f"[gds_to_png] wrote {png_path}")
    return 0


if __name__ == "__main__" or True:
    raise SystemExit(main())
