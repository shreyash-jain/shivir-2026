#!/usr/bin/env sh
#
# Assemble app/www for the Android build.
#
#   www/             <- ../scanner, copied verbatim
#   www/config.json  <- the live site's /config.json (project URL + key)
#
# Inside the APK the page loads from https://localhost, where there is no
# Cloudflare Worker to serve /config.json, so the server details are baked in
# here at build time. Without this every APK phone would open on the fallback
# paste-a-setup-code screen instead of the login.
#
# The publishable key is public by design; baking it in is the same as the
# site serving it. codes.csv is deliberately NOT bundled -- the roll arrives
# with the volunteer's login, and an APK gets forwarded around on WhatsApp.
#
# Usage: sh build_www.sh [site-url]
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SITE=${1:-https://shivir-attendance.shreyash-d60.workers.dev}
OUT="$HERE/www"

rm -rf "$OUT"; mkdir -p "$OUT"
for f in index.html jsQR.min.js sw.js manifest.json icon.svg; do
  cp "$HERE/../scanner/$f" "$OUT/"
done

if curl -sSf --max-time 20 "$SITE/config.json" -o "$OUT/config.json"; then
  if grep -q '"supaUrl":"https' "$OUT/config.json"; then
    echo "config.json baked in from $SITE"
  else
    echo "WARNING: $SITE/config.json has no server details; phones will need the setup code" >&2
  fi
else
  echo "WARNING: could not fetch $SITE/config.json; phones will need the setup code" >&2
  rm -f "$OUT/config.json"
fi
echo "www assembled in $OUT"
