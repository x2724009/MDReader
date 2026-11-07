"""Pack PNGs named <size>.png from a folder into a Windows .ico (PNG-compressed entries)."""
import os, struct, sys

src, dst = sys.argv[1], sys.argv[2]
sizes = sorted(int(f[:-4]) for f in os.listdir(src) if f.endswith(".png") and f[:-4].isdigit())
blobs = [open(os.path.join(src, f"{s}.png"), "rb").read() for s in sizes]
out = bytearray(struct.pack("<HHH", 0, 1, len(sizes)))
offset = 6 + 16 * len(sizes)
for s, b in zip(sizes, blobs):
    out += struct.pack("<BBBBHHII", 0 if s >= 256 else s, 0 if s >= 256 else s, 0, 0, 1, 32, len(b), offset)
    offset += len(b)
for b in blobs:
    out += b
open(dst, "wb").write(out)
print(f"{dst}: {sizes}")
