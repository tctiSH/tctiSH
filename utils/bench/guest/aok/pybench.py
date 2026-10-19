# Pure-Python mix: recursion, integer loops, dicts, strings, objects, floats. pybench.py SCALE
import sys
def fib(n): return n if n < 2 else fib(n - 1) + fib(n - 2)
def sieve(n):
    s = bytearray([1]) * (n + 1); s[0:2] = b"\0\0"
    for i in range(2, int(n ** 0.5) + 1):
        if s[i]: s[i * i::i] = bytes(len(range(i * i, n + 1, i)))
    return sum(s)
def words(n):
    seed = 12345; out = []
    for _ in range(n):
        seed = (seed * 1103515245 + 12345) & 0x7fffffff
        out.append("w%d" % (seed % 5000))
    counts = {}
    for w in out: counts[w] = counts.get(w, 0) + 1
    return len(" ".join(sorted(counts, key=lambda k: (-counts[k], k))[:100]))
class Vec:
    __slots__ = ("x", "y")
    def __init__(self, x, y): self.x = x; self.y = y
    def add(self, o): return Vec(self.x + o.x, self.y + o.y)
def objects(n):
    v = Vec(0.0, 0.0); d = Vec(0.5, 0.25)
    for _ in range(n): v = v.add(d)
    return v.x + v.y
def floats(n):
    t = 0.0
    for i in range(1, n): t += (i * 1.000001) / (i + 3.0)
    return t
scale = int(sys.argv[1]) if len(sys.argv) > 1 else 1
r = 0
for _ in range(scale):
    r += fib(24) + sieve(300000) + words(120000) + int(objects(150000)) + int(floats(300000))
print(r)
