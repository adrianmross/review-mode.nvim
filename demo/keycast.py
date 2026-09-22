#!/usr/bin/env python3
"""Draw the keys a take pressed, as chips, and the filter chain to overlay them.

    demo/keycast.py demo/suggestion.keys.json 1538 982 /tmp/keys

A viewer cannot see a keystroke. Without chips, the hero moment of this plugin
-- one key turning an edit into a suggestion -- looks like the editor doing
something on its own. record.py logs what it pressed and when; this renders each
press as a chip and prints the overlay chain, the same shape captions.py uses.

Typed prose is skipped: the point is the bindings, not the sentence. Chips hold
for `HOLD` seconds, and a run of presses inside `GROUP` seconds becomes one chip
(`]c` is two keys and one gesture).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HOLD = 1.6
GROUP = 0.45
FONT_CANDIDATES = (
    "/System/Library/Fonts/SFNSMono.ttf",
    "/System/Library/Fonts/Menlo.ttc",
    "/System/Library/Fonts/Supplemental/Courier New Bold.ttf",
)


def font(size: int) -> ImageFont.FreeTypeFont:
    for candidate in FONT_CANDIDATES:
        if Path(candidate).exists():
            return ImageFont.truetype(candidate, size)
    return ImageFont.load_default()


def interesting(press: dict) -> bool:
    """Bindings and motions, not the words someone typed into a draft."""
    key = press["key"]
    if key.startswith(("<leader>", "<C-")):
        return True
    if key in ("<Escape>", "<Enter>", "<Tab>"):
        return True
    return len(key) <= 3 and not key[0].isalpha() or key in ("cc", "q", "D", "P", "za", "zR")


def chips(presses: list[dict]) -> list[tuple[float, float, str]]:
    out: list[tuple[float, float, str]] = []
    for press in presses:
        if not interesting(press):
            continue
        start, key = press["t"], press["key"]
        if out and start - out[-1][0] < GROUP:
            previous = out.pop()
            out.append((previous[0], start + HOLD, f"{previous[2]} {key}"))
        else:
            out.append((start, start + HOLD, key))
    return out


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    log, width, height, out_dir = Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), Path(sys.argv[4])
    out_dir.mkdir(parents=True, exist_ok=True)
    presses = json.loads(log.read_text())

    size = max(18, width // 52)
    face = font(size)
    pad = int(size * 0.7)

    filters, label = [], "[base]"
    for index, (start, end, text) in enumerate(chips(presses)):
        box = ImageDraw.Draw(Image.new("RGBA", (1, 1))).textbbox((0, 0), text, font=face)
        text_w, text_h = box[2] - box[0], box[3] - box[1]
        chip_w, chip_h = text_w + pad * 3, text_h + pad * 2
        image = Image.new("RGBA", (chip_w, chip_h), (0, 0, 0, 0))
        draw = ImageDraw.Draw(image)
        # a key on a dark terminal needs an edge, not just a fill
        draw.rounded_rectangle((0, 0, chip_w - 1, chip_h - 1), radius=pad, fill=(30, 32, 40, 235), outline=(120, 200, 255, 255), width=2)
        draw.text(((chip_w - text_w) // 2 - box[0], (chip_h - text_h) // 2 - box[1]), text, font=face, fill=(235, 245, 255, 255))
        png = out_dir / f"key{index:02d}.png"
        image.save(png)

        nxt = f"[key{index}]"
        # top right, clear of the code and of the captions along the bottom
        filters.append(
            f"{label}[{index + 1}:v]overlay=x=W-w-{size * 2}:y={size}:"
            f"enable='between(t,{start:.2f},{end:.2f})'{nxt}"
        )
        label = nxt
        print(f"input:{png}", file=sys.stderr)

    if not filters:
        print("[base]null[keyed]")
        return 0
    filters[-1] = filters[-1].replace(label, "[keyed]")
    print(";".join(filters))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
