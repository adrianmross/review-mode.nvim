#!/usr/bin/env python3
"""Render an .srt as caption PNGs plus the ffmpeg overlay filter to burn them.

    demo/captions.py demo/suggestion.srt 1400 800 /tmp/caps

Homebrew's ffmpeg arrives without libass or freetype here, so `subtitles=` and
`drawtext=` do not exist and captions cannot be burned by ffmpeg alone. Pillow
draws each line into a transparent strip instead, and the strips are composited
with plain `overlay` filters, which every build has.

Prints the filter chain on stdout: feed it the video label to draw on, and it
yields [captioned].
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

FONT_CANDIDATES = (
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
)


def seconds(stamp: str) -> float:
    hours, minutes, rest = stamp.split(":")
    whole, _, millis = rest.partition(",")
    return int(hours) * 3600 + int(minutes) * 60 + int(whole) + int(millis or 0) / 1000


def cues(path: Path) -> list[tuple[float, float, str]]:
    out = []
    for block in re.split(r"\n\s*\n", path.read_text().strip()):
        lines = [line for line in block.splitlines() if line.strip()]
        if len(lines) < 2:
            continue
        timing = next((line for line in lines if "-->" in line), None)
        if not timing:
            continue
        start, _, end = timing.partition("-->")
        text = " ".join(lines[lines.index(timing) + 1 :]).strip()
        out.append((seconds(start.strip()), seconds(end.strip()), text))
    return out


def font(size: int) -> ImageFont.FreeTypeFont:
    for candidate in FONT_CANDIDATES:
        if Path(candidate).exists():
            return ImageFont.truetype(candidate, size)
    return ImageFont.load_default()


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    srt, width, height, out_dir = Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), Path(sys.argv[4])
    out_dir.mkdir(parents=True, exist_ok=True)

    size = max(16, width // 58)
    face = font(size)
    pad = size // 2
    strip_height = size * 2 + pad * 2

    filters, label = [], "[base]"
    for index, (start, end, text) in enumerate(cues(srt)):
        image = Image.new("RGBA", (width, strip_height), (0, 0, 0, 0))
        draw = ImageDraw.Draw(image)
        box = draw.textbbox((0, 0), text, font=face)
        text_w, text_h = box[2] - box[0], box[3] - box[1]
        x = (width - text_w) // 2
        y = (strip_height - text_h) // 2
        # a panel behind the words: a caption over a dark terminal needs a floor
        draw.rounded_rectangle(
            (x - pad * 2, y - pad, x + text_w + pad * 2, y + text_h + pad),
            radius=pad,
            fill=(12, 12, 16, 220),
        )
        draw.text((x, y), text, font=face, fill=(255, 255, 255, 255))
        png = out_dir / f"cap{index:02d}.png"
        image.save(png)

        nxt = f"[cap{index}]"
        filters.append(
            f"{label}[{index + 1}:v]overlay=x=0:y=H-h-{int(strip_height * 1.4)}:"
            f"enable='between(t,{start},{end})'{nxt}"
        )
        label = nxt
        print(f"input:{png}", file=sys.stderr)

    if not filters:
        print("[base]null[captioned]")
        return 0
    filters[-1] = filters[-1].replace(label, "[captioned]")
    print(";".join(filters))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
