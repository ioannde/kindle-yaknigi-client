#!/usr/bin/env python3
"""Puts the icons exported from Figma into the plugin.

The drawings live in Figma: https://www.figma.com/design/PL4AdQblwpez3CL1457dco
Each component there is named as its file here. The input is JSON, { name: svg as Figma
exports it }. Anything that breaks the rules of the set stops the import, so a drawing
that would look different from the others, or that KOReader's nanosvg could not draw,
does not get in.

    python3 tools/icons/import_figma.py exported.json
"""
import json, os, re, sys

PLUGIN = os.path.join(os.path.dirname(__file__), "..", "..", "koreader", "yaknigi.koplugin", "yaknigi")
OUT = os.path.join(PLUGIN, "icons")
INK = os.path.join(PLUGIN, "iconink.lua")
GRID = 24
STROKE = "2.2"
IDLE = {"tab.library", "yandex-books", "tab.search", "tab.settings"}  # the tab bar's unselected look
IDLE_COLOUR = "#888888"  # KOReader's COLOR_DARK_GRAY, as the idle captions
FORBIDDEN = ("clip-path", "clipPath", "mask", "filter", "<style", "<image", "<use", "<defs", "transform", "class=")


def tidy_number(match):
    number = float(match.group(0))
    text = ("%.2f" % number).rstrip("0").rstrip(".")
    return "0" if text in ("", "-0") else text


def clean(name, svg):
    for word in FORBIDDEN:
        if word in svg:
            raise SystemExit("%s: has %s" % (name, word))
    if 'viewBox="0 0 24 24"' not in svg:
        raise SystemExit("%s: is not on the 24 grid" % name)
    widths = set(re.findall(r'stroke-width="([^"]+)"', svg))
    if widths - {STROKE}:
        raise SystemExit("%s: stroke %s, the set has %s" % (name, sorted(widths), STROKE))
    colours = set(re.findall(r'(?:stroke|fill)="([^"]+)"', svg)) - {"none"}
    if colours - {"black", "white"}:
        raise SystemExit("%s: colours %s" % (name, sorted(colours)))
    svg = re.sub(r' d="([^"]+)"', lambda m: ' d="%s"' % re.sub(r"-?\d*\.\d+", tidy_number, m.group(1)), svg)
    return svg.replace('stroke="black"', 'stroke="#000"').replace('fill="black"', 'fill="#000"') \
        .replace('fill="white"', 'fill="#fff"').replace("\n", "") + "\n"


def bounds(svg):
    """What a drawing covers, stroke included: x0, y0, x1, y1 on the grid."""
    xs, ys = [], []
    for d in re.findall(r' d="([^"]+)"', svg):
        tokens = re.findall(r"[A-Za-z]|-?\d*\.?\d+(?:e-?\d+)?", d)
        x, y, i = 0.0, 0.0, 0
        while i < len(tokens):
            op = tokens[i]
            i += 1
            if op in "ML":
                x, y = float(tokens[i]), float(tokens[i + 1])
                i += 2
            elif op == "H":
                x = float(tokens[i])
                i += 1
            elif op == "V":
                y = float(tokens[i])
                i += 1
            elif op == "C":
                p = [float(t) for t in tokens[i:i + 6]]
                i += 6
                for step in range(1, 33):
                    t = step / 32
                    a, b, c, e = (1 - t) ** 3, 3 * t * (1 - t) ** 2, 3 * t * t * (1 - t), t ** 3
                    xs.append(a * x + b * p[0] + c * p[2] + e * p[4])
                    ys.append(a * y + b * p[1] + c * p[3] + e * p[5])
                x, y = p[4], p[5]
            elif op != "Z":
                raise SystemExit("unknown path command " + op)
            xs.append(x)
            ys.append(y)
    half = float(STROKE) / 2
    return min(xs) - half, min(ys) - half, max(xs) + half, max(ys) + half


def write_ink(icons):
    lines = [
        "-- Made by tools/icons/import_figma.py from the drawings, not to be edited by hand.",
        "-- How much empty room each icon has around what is drawn, as a share of its side.",
        "return {",
    ]
    for name in sorted(icons):
        x0, y0, x1, y1 = bounds(icons[name])
        lines.append('    ["%s"] = { left = %.4f, right = %.4f, top = %.4f, bottom = %.4f },' % (
            name, x0 / GRID, (GRID - x1) / GRID, y0 / GRID, (GRID - y1) / GRID))
    lines.append("}")
    with open(INK, "w", encoding="utf-8") as out:
        out.write("\n".join(lines) + "\n")


def main():
    icons = json.load(open(sys.argv[1], encoding="utf-8"))
    wanted = set()
    cleaned = {}
    for name, svg in icons.items():
        text = cleaned[name] = clean(name, svg)
        files = {name: text}
        if name in IDLE:
            files[name + ".idle"] = text.replace('"#000"', '"%s"' % IDLE_COLOUR)
        for file, body in files.items():
            wanted.add(file + ".svg")
            with open(os.path.join(OUT, file + ".svg"), "w", encoding="utf-8") as out:
                out.write(body)
    for stale in set(os.listdir(OUT)) - wanted:
        if stale.endswith(".svg"):
            os.remove(os.path.join(OUT, stale))
            print("removed", stale)
    write_ink(cleaned)
    print(len(wanted), "files")


main()
