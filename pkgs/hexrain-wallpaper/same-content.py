"""same-content.py <apk> <apk> — exit 0 when both APKs hold the same entries
with the same bytes. Signing doesn't change the entries (minSdk 31 signs with
the v2/v3 APK signing block, outside the zip entries), so a signed APK
matches the unsigned build it was signed from."""
import sys
import zipfile


def entries(path):
    with zipfile.ZipFile(path) as z:
        return {i.filename: z.read(i) for i in z.infolist() if not i.filename.startswith("META-INF/")}


a, b = (entries(p) for p in sys.argv[1:3])
differing = sorted(n for n in a.keys() | b.keys() if a.get(n) != b.get(n))
for name in differing:
    print(f"  differs: {name}", file=sys.stderr)
sys.exit(1 if differing else 0)
