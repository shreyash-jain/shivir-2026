#!/usr/bin/env sh
#
# Assemble the deployable site into dist/.
#
# This is NOT a build step for the scanner -- every file is copied verbatim,
# nothing is compiled, bundled or minified. The one exception is a twelve
# character build stamp substituted into sw.js so phones notice a new version. It exists only to decide what gets published: the app and the
# dashboard, and none of the docs, tests or tooling.
#
#   dist/            <- scanner/, so volunteers get a bare URL
#   dist/admin/      <- admin/     (super admin: sessions, volunteers, assignments)
#   dist/dashboard/  <- dashboard/ (a redirect to /admin, for links already sent)
#
# Usage: sh tools/build_site.sh [outdir]
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:-"$ROOT/dist"}

rm -rf "$OUT"
mkdir -p "$OUT/dashboard" "$OUT/admin"

# The scanner, at the root of the site.
cp "$ROOT/scanner/index.html"    "$OUT/"
cp "$ROOT/scanner/jsQR.min.js"   "$OUT/"
# Stamp the service worker with a hash of what it caches. A changed stamp is
# what makes a phone that already has the app pick up the new version; a
# fixed name meant the first version ever loaded was the last one it saw.
STAMP=$(cat "$ROOT/scanner/index.html" "$ROOT/scanner/sw.js" "$ROOT/scanner/jsQR.min.js" \
        | shasum -a 256 | cut -c1-12)
sed "s/__BUILD__/$STAMP/" "$ROOT/scanner/sw.js" > "$OUT/sw.js"
echo "service worker cache: attendance-$STAMP"
cp "$ROOT/scanner/manifest.json" "$OUT/"
cp "$ROOT/scanner/icon.svg"      "$OUT/"

# The participant list, if one has been placed. It is gitignored and absent
# from CI, in which case volunteers pick the file during setup instead.
if [ -f "$ROOT/scanner/codes.csv" ]; then
  cp "$ROOT/scanner/codes.csv" "$OUT/"
  echo "included codes.csv ($(wc -l < "$ROOT/scanner/codes.csv" | tr -d ' ') lines)"
else
  echo "no scanner/codes.csv -- phones will need the file picker on setup"
fi

cp "$ROOT/admin/index.html"     "$OUT/admin/"
cp "$ROOT/dashboard/index.html" "$OUT/dashboard/"

# Never cache the app shell. A phone that caches a stale index.html keeps an
# old service worker and an old sync path for the rest of the event; the
# service worker handles offline, so the network copy must always be fresh.
cat > "$OUT/_headers" <<'EOF'
/*
  X-Frame-Options: DENY
  X-Content-Type-Options: nosniff
  Referrer-Policy: no-referrer

/index.html
  Cache-Control: no-cache

/sw.js
  Cache-Control: no-cache

/dashboard/index.html
  Cache-Control: no-cache

/admin/index.html
  Cache-Control: no-cache

/codes.csv
  Cache-Control: no-store
EOF

echo "site assembled in $OUT"
