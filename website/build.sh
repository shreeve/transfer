#!/bin/bash
# Builds the product page into website/dist, plain files any static host serves (GitHub Pages
# among them), and prints the folder. The page is Rip: `bundle.json` carries its modules, which
# Rip's browser runtime compiles and renders, styled by Rip's Tailwind runtime from index.css.
#
# RIP is the Rip checkout the two runtimes come from (default ~/Data/Code/rip); VERSION is the
# release the page offers (default: the latest v* tag).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
rip="${RIP:-$HOME/Data/Code/rip}"
version="${VERSION:-$(git -C "$root" tag --list 'v*' --sort=-v:refname | head -1 | sed 's/^v//')}"
out="$here/dist"

[ -f "$rip/dist/@rip/rip.min.js" ] || { echo "error: no Rip runtime at $rip/dist/@rip (set RIP)" >&2; exit 1; }
[ -n "$version" ] || { echo "error: no v* tag to offer (set VERSION)" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out/@rip"
cp "$here/app/index.html" "$here/app/index.css" "$out/"
cp "$rip/dist/@rip/rip.min.js" "$rip/dist/@rip/tailwind.min.js" "$out/@rip/"
cp "$root/Support/AppIcon.svg" "$out/icon.svg"
sips -s format png -Z 512 "$root/Support/AppIcon.icns" --out "$out/icon.png" >/dev/null
# GitHub Pages serves the folder as it is, not through Jekyll, which would hide `@rip`.
touch "$out/.nojekyll"

# The program: every .rip module under app/, by its path there, and the version, as Rip's
# manager publishes an App (`{ hash, list: [[path, source], ...] }`, sorted by path).
python3 - "$here/app" "$version" "$out/bundle.json" <<'EOF'
import hashlib, json, os, sys
app, version, out = sys.argv[1:]
modules = {"version.rip": f"export VERSION = '{version}'\n"}
for folder, _, files in os.walk(app):
    for name in files:
        if name.endswith(".rip"):
            path = os.path.join(folder, name)
            modules[os.path.relpath(path, app)] = open(path, encoding="utf-8").read()
listing = sorted(modules.items())
digest = hashlib.sha256(json.dumps(listing).encode()).hexdigest()[:6]
json.dump({"hash": digest, "list": listing}, open(out, "w"), ensure_ascii=False)
EOF

echo "$out"
