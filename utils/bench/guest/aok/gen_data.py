# Deterministic pseudo-text for the compression and hashing workloads. gen_data.py PATH MEGABYTES
import sys
path, mb = sys.argv[1], int(sys.argv[2])
seed = 20261011
vocab = []
for i in range(4000):
    seed = (seed * 6364136223846793005 + 1442695040888963407) & (2**64 - 1)
    n = 2 + (seed >> 60)
    w = bytearray()
    s = seed
    for _ in range(n):
        s = (s * 6364136223846793005 + 1442695040888963407) & (2**64 - 1)
        w.append(97 + (s >> 59) % 26)
    vocab.append(bytes(w))
out = bytearray(); target = mb << 20
while len(out) < target:
    seed = (seed * 6364136223846793005 + 1442695040888963407) & (2**64 - 1)
    idx = (seed >> 33) % 4000
    idx = idx * idx // 4000          # skew towards common words
    out += vocab[idx]
    out += b"\n" if (seed >> 20) % 13 == 0 else b" "
open(path, "wb").write(out[:target])
