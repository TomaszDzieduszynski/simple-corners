RIDGE=None
# Draws the toolbar icons: a block corner seen in profile, with the top-right
# corner rounded (round), rounded edges meeting at a crest (sharp) or cut flat
# (bevel). Rendered at 8x and downsampled for antialiasing.
import sys, math
from PIL import Image, ImageDraw
out = sys.argv[1]
FILL = (232, 160, 60, 255)      # body
EDGE = (60, 60, 70, 255)        # outline
HI = (215, 25, 25, 255)         # highlighted new surface (red)

def shape(mode, S):
    # unit square body from (0.12,0.12) to (0.88,0.88), y up; corner at top-right
    a, b = 0.14, 0.86
    r = 0.42
    pts = []
    if mode == 'round':
        pts = [(a, a), (b, a), (b, b - r)]
        for i in range(0, 21):
            t = i / 20 * math.pi / 2
            pts.append((b - r + r * math.cos(t), b - r + r * math.sin(t)))
        pts += [(a, b)]
        hi = pts[2:-1]
    elif mode == 'bevel':
        pts = [(a, a), (b, a), (b, b - r), (b - r, b), (a, b)]
        hi = [(b, b - r), (b - r, b)]
    else:  # sharp: two rounded edges meeting at a pointed crest (ridge)
        k = 0.10
        C = (b - k, b - k)
        def quad(p0, c, p1, n=12):
            return [((1-t)**2*p0[0] + 2*t*(1-t)*c[0] + t*t*p1[0], (1-t)**2*p0[1] + 2*t*(1-t)*c[1] + t*t*p1[1]) for t in [i/n for i in range(n+1)]]
        a1 = quad((b, b - r), (b, b - k * 0.6), C)
        a2 = quad(C, (b - k * 0.6, b), (b - r, b))
        pts = [(a, a), (b, a)] + a1 + a2[1:] + [(a, b)]
        hi = a1 + a2[1:]
        global RIDGE
        RIDGE = [C, (b - r * 0.75, b - r * 0.75)]
    to = lambda p: (p[0] * S, (1 - p[1]) * S)
    return [to(p) for p in pts], [to(p) for p in hi]

def icon(mode, size):
    S = size * 8
    im = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    body, hi = shape(mode, S)
    d.polygon(body, fill=FILL)
    w = max(2, int(S * 0.06))
    d.line(body + [body[0]], fill=EDGE, width=w, joint='curve')
    d.line(hi, fill=HI, width=int(w * 3.6), joint='curve')
    if mode == 'sharp':
        d.line([(RIDGE[0][0]*S, (1-RIDGE[0][1])*S), (RIDGE[1][0]*S, (1-RIDGE[1][1])*S)], fill=HI, width=int(w*2.4))
    return im.resize((size, size), Image.LANCZOS)

for mode in ['round', 'sharp', 'bevel']:
    for size in [16, 24, 32]:
        icon(mode, size).save(f'{out}/{mode}_{size}.png')
    icon(mode, 96).save(f'{out}/preview_{mode}.png')
    # Cursor 32x32: crosshair with hotspot (3, 3) and a small icon.
    S = 32 * 8
    cur = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(cur)
    h = 3 * 8 + 4
    for col, wd in [((255, 255, 255, 255), 28), ((0, 0, 0, 255), 12)]:
        d.line([(h, 0), (h, 13 * 8)], fill=col, width=wd)
        d.line([(0, h), (13 * 8, h)], fill=col, width=wd)
    small = icon(mode, 18).resize((18 * 8, 18 * 8), Image.LANCZOS)
    cur.alpha_composite(small, (13 * 8, 13 * 8))
    cur.resize((32, 32), Image.LANCZOS).save(f'{out}/cursor_{mode}.png')

# Smoothing icons.
def smooth_new(size):
    # Quarter-round surface shaded smoothly, red outline arc.
    S = size * 8
    im = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    a, b, r = 0.14 * S, 0.86 * S, 0.62 * S
    cx, cy = a, b  # quarter circle centred bottom-left
    for k in range(60, 0, -1):
        rr = r * k / 60
        shade = int(150 + 100 * (k / 60))
        d.pieslice([cx - rr, cy - rr, cx + rr, cy + rr], 270, 360, fill=(255, shade, 60, 255))
    w = max(2, int(S * 0.06))
    d.arc([cx - r, cy - r, cx + r, cy + r], 270, 360, fill=HI, width=int(w * 3.6))
    d.line([(cx, cy - r), (cx, cy), (cx + r, cy)], fill=EDGE, width=w)
    return im.resize((size, size), Image.LANCZOS)

def smooth_sel(size):
    # Faceted quarter-round: three flat facets (strong shades) with thick
    # dark seams = visible edges; thick smooth red arc on the rim = smooth.
    S = size * 8
    im = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    w = max(2, int(S * 0.06))
    cx, cy, r = 0.10 * S, 0.90 * S, 0.66 * S
    angs = [0, 30, 60, 90]
    pts = [(cx + r * math.sin(math.radians(a)), cy - r * math.cos(math.radians(a))) for a in angs]
    shades = [(255, 205, 120, 255), (235, 150, 50, 255), (190, 105, 25, 255)]
    for k in range(3):
        d.polygon([(cx, cy), pts[k], pts[k + 1]], fill=shades[k])
    for k in (1, 2):
        d.line([(cx, cy), pts[k]], fill=EDGE, width=int(w * 1.6))
    d.line([(cx, cy - r), (cx, cy), (cx + r, cy)], fill=EDGE, width=w)
    d.line(pts, fill=EDGE, width=w)
    rr = r + 0.13 * S
    d.arc([cx - rr, cy - rr, cx + rr, cy + rr], 270, 360, fill=HI, width=int(w * 3.0))
    return im.resize((size, size), Image.LANCZOS)

def unround(size):
    # Block with its sharp corner restored (red), old fillet dashed.
    S = size * 8
    im = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    a, b, r = 0.14 * S, 0.86 * S, 0.42 * S
    w = max(2, int(S * 0.06))
    d.polygon([(a, b), (a, a), (b, a), (b, b)], fill=FILL)
    d.line([(a, a), (b, a)], fill=EDGE, width=w)
    d.line([(a, a), (a, b), (b, b)], fill=EDGE, width=w)
    # dashed old fillet
    for i in range(4):
        t0 = math.radians(90 * (i + 0.2) / 4)
        t1 = math.radians(90 * (i + 0.75) / 4)
        cx, cy = b - r, a + r
        d.line([(cx + r * math.sin(t0), cy - r * math.cos(t0)), (cx + r * math.sin(t1), cy - r * math.cos(t1))],
               fill=EDGE, width=w)
    # restored sharp corner in red
    d.line([(b - r, a), (b, a), (b, a + r)], fill=HI, width=int(w * 3.6), joint='curve')
    return im.resize((size, size), Image.LANCZOS)

for size in [16, 24, 32]:
    smooth_new(size).save(f'{out}/smooth_new_{size}.png')
    smooth_sel(size).save(f'{out}/smooth_sel_{size}.png')
    unround(size).save(f'{out}/unround_{size}.png')
