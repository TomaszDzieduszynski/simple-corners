"""Draws the toolbar icons and cursors as vectors: SVG (SketchUp 2016+ on
Windows) and PDF (SketchUp 2016+ on macOS).

The SVGs stay within what SketchUp's Windows renderer supports: SVG 1.1
with a DOCTYPE, presentation attributes only (no <style>), flat colours (no
gradients), no clip paths, filters or embedded images. Curves are written as
polylines.

Usage: python3 scripts/make_vector_icons.py [output_dir]
Needs: pip install cairosvg  (only for the PDF files)
"""
import math
import os
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'simple_corners', 'icons')

FILL = '#E8A03C'
EDGE = '#3C3C46'
RED = '#D71919'
VB = 24.0           # icon view box size
W = 0.06 * VB       # outline width (matches the PNG icons)

HEAD = ('<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" '
        '"http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">\n')


def P(x, y):
    """Normalised point (0..1, y up) -> view box coordinates."""
    return (x * VB, (1 - y) * VB)


def pts(points):
    return ' '.join('%.3f,%.3f' % P(x, y) for x, y in points)


def polygon(points, fill, stroke=None, width=0.0):
    s = '<polygon points="%s" fill="%s"' % (pts(points), fill)
    if stroke:
        s += ' stroke="%s" stroke-width="%.3f" stroke-linejoin="round"' % (stroke, width)
    return s + '/>'


def polyline(points, stroke, width):
    return ('<polyline points="%s" fill="none" stroke="%s" stroke-width="%.3f" '
            'stroke-linejoin="round" stroke-linecap="round"/>' % (pts(points), stroke, width))


def arc(cx, cy, r, a0, a1, n=24):
    """Points on a circle (normalised coords), angles in degrees, 0 = +x."""
    return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)),
             cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]


def quad(p0, c, p1, n=12):
    return [((1 - t) ** 2 * p0[0] + 2 * t * (1 - t) * c[0] + t * t * p1[0],
             (1 - t) ** 2 * p0[1] + 2 * t * (1 - t) * c[1] + t * t * p1[1])
            for t in [i / n for i in range(n + 1)]]


A, B, R = 0.14, 0.86, 0.42  # block corners and corner size


def icon_round():
    curve = arc(B - R, B - R, R, 0, 90)
    body = [(A, A), (B, A)] + curve + [(A, B)]
    return [polygon(body, FILL, EDGE, W), polyline(curve, RED, W * 3.6)]


def icon_sharp():
    k = 0.10
    c = (B - k, B - k)
    a1 = quad((B, B - R), (B, B - k * 0.6), c)
    a2 = quad(c, (B - k * 0.6, B), (B - R, B))
    body = [(A, A), (B, A)] + a1 + a2[1:] + [(A, B)]
    return [polygon(body, FILL, EDGE, W), polyline(a1 + a2[1:], RED, W * 3.6),
            polyline([c, (B - R * 0.75, B - R * 0.75)], RED, W * 2.4)]


def icon_bevel():
    body = [(A, A), (B, A), (B, B - R), (B - R, B), (A, B)]
    return [polygon(body, FILL, EDGE, W), polyline([(B, B - R), (B - R, B)], RED, W * 3.6)]


def icon_smooth_new():
    # Quarter round in flat bands (no gradients), red rim.
    cx, cy, r = 0.14, 0.14, 0.62
    shades = ['#FFE6A0', '#FFD27A', '#F7B955', '#EE9F3C']
    out = []
    for i, col in enumerate(shades):
        rr = r * (len(shades) - i) / len(shades)
        out.append(polygon([(cx, cy)] + arc(cx, cy, rr, 0, 90), col))
    out.append(polyline(arc(cx, cy, r, 0, 90), RED, W * 3.6))
    out.append(polyline([(cx, cy + r), (cx, cy), (cx + r, cy)], EDGE, W))
    return out


def icon_smooth_sel():
    # Three flat facets with thick dark seams, smooth red rim.
    cx, cy, r = 0.10, 0.10, 0.66
    corners = [(cx + r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a)))
               for a in (90, 60, 30, 0)]
    shades = ['#FFCD78', '#EB9632', '#BE6919']
    out = [polygon([(cx, cy), corners[k], corners[k + 1]], shades[k]) for k in range(3)]
    out += [polyline([(cx, cy), corners[k]], EDGE, W * 1.6) for k in (1, 2)]
    out.append(polyline([(cx, cy + r), (cx, cy), (cx + r, cy)], EDGE, W))
    out.append(polyline(corners, EDGE, W))
    out.append(polyline(arc(cx, cy, r + 0.13, 0, 90), RED, W * 3.0))
    return out


def icon_unround():
    out = [polygon([(A, A), (A, B), (B, B), (B, A)], FILL),
           polyline([(A, B), (A, A), (B, A)], EDGE, W),
           polyline([(B - R, B), (B, B), (B, B - R)], RED, W * 3.6)]
    return out


ICONS = {
    'round': icon_round, 'sharp': icon_sharp, 'bevel': icon_bevel,
    'smooth_new': icon_smooth_new, 'smooth_sel': icon_smooth_sel, 'unround': icon_unround,
}


def svg(size, body):
    return (HEAD + '<svg xmlns="http://www.w3.org/2000/svg" version="1.1" width="%d" height="%d" '
            'viewBox="0 0 %d %d">\n%s\n</svg>\n' % (size, size, size, size, '\n'.join(body)))


def cursor(name):
    # 32x32 cursor: crosshair with hotspot (3, 3), small icon at bottom right.
    h = 3.5
    cross = []
    for col, wd in (('#FFFFFF', 3.5), ('#000000', 1.5)):
        cross.append('<line x1="%.1f" y1="0" x2="%.1f" y2="13" stroke="%s" stroke-width="%.1f"/>' % (h, h, col, wd))
        cross.append('<line x1="0" y1="%.1f" x2="13" y2="%.1f" stroke="%s" stroke-width="%.1f"/>' % (h, h, col, wd))
    icon = '<g transform="translate(13 13) scale(%.4f)">%s</g>' % (18.0 / VB, ''.join(ICONS[name]()))
    return svg(32, cross + [icon])


def main():
    os.makedirs(OUT, exist_ok=True)
    try:
        import cairosvg
    except ImportError:
        cairosvg = None
        print('cairosvg not installed: writing SVG only (no PDF for macOS)')
    files = {}
    for name, fn in ICONS.items():
        files[name] = svg(int(VB), fn())
    for name in ('round', 'sharp', 'bevel'):
        files['cursor_' + name] = cursor(name)
    for name, text in files.items():
        path = os.path.join(OUT, name + '.svg')
        with open(path, 'w', encoding='utf-8') as f:
            f.write(text)
        if cairosvg:
            cairosvg.svg2pdf(bytestring=text.encode('utf-8'), write_to=os.path.join(OUT, name + '.pdf'))
    print('wrote %d icons to %s' % (len(files), os.path.abspath(OUT)))


if __name__ == '__main__':
    main()
