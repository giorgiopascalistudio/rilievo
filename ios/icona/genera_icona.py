# Icona Rilievo: pianta a L stile blueprint, quota misurata e diagonale tratteggiata.
import math, sys
from PIL import Image, ImageDraw, ImageFilter
S = 1024; K = 4; N = S * K
img = Image.new("RGB", (N, N))
d = ImageDraw.Draw(img)
top, bot = (40, 42, 46), (22, 23, 26)
for y in range(N):
    t = y / N
    d.line([(0, y), (N, y)], fill=tuple(int(top[i] * (1 - t) + bot[i] * t) for i in range(3)))
# griglia
g = (52, 55, 60)
for k in range(1, 12):
    x = int(N * k / 12)
    d.line([(x, 0), (x, N)], fill=g, width=K * 2)
    d.line([(0, x), (N, x)], fill=g, width=K * 2)
def P(x, y): return (int(x * N), int(y * N))
pianta = [P(.22, .24), P(.78, .24), P(.78, .56), P(.56, .56), P(.56, .78), P(.22, .78)]
# alone
alone = Image.new("RGB", (N, N)); da = ImageDraw.Draw(alone)
da.line(pianta + [pianta[0]], fill=(0, 0, 0), width=K * 2, joint="curve")
alone = alone.filter(ImageFilter.GaussianBlur(K * 30))
img = Image.blend(img, alone, 0.0)
img = Image.composite(alone, img, alone.convert("L").point(lambda v: int(v * 0.55)))
d = ImageDraw.Draw(img)
d.polygon(pianta, fill=(48, 50, 55))
d.line(pianta + [pianta[0]], fill=(238, 240, 243), width=K * 26, joint="curve")
# diagonale tratteggiata arancione
a, b = P(.22, .24), P(.56, .78)
L = math.dist(a, b); n = 9
for i in range(n):
    t0, t1 = i / n, (i + 0.55) / n
    d.line([(a[0] + (b[0] - a[0]) * t0, a[1] + (b[1] - a[1]) * t0), (a[0] + (b[0] - a[0]) * t1, a[1] + (b[1] - a[1]) * t1)],
           fill=(220, 168, 97), width=K * 10)
# quota verde sopra
y = int(.15 * N); x0, x1 = P(.22, 0)[0], P(.78, 0)[0]
c = (92, 148, 235)
d.line([(x0, y), (x1, y)], fill=c, width=K * 10)
for x in (x0, x1):
    d.line([(x, y - K * 28), (x, y + K * 28)], fill=c, width=K * 10)
    d.line([(x - K * 20, y + K * 20), (x + K * 20, y - K * 20)], fill=c, width=K * 10)
# punto laser
r = K * 18
for cx, cy in (P(.22, .24), P(.56, .78)):
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(92, 148, 235))
img.resize((S, S), Image.LANCZOS).save(sys.argv[1])
