#!/bin/bash
# Makes the pictures and guide that go in the .dmg, using Chrome to draw the HTML:
#   <out>/background.png and background@2x.png   the installer window's background
#   <out>/READ ME FIRST.pdf                        the guide, with the version filled in
#
#   dmg/make.sh <version> <out folder> <app icon png>
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$1"
OUT="$2"
ICON="$3"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

mkdir -p "$OUT/guide"
trap 'rm -rf "$OUT/guide"' EXIT

# chrome <file it will write> <args…>: headless Chrome writes the file but doesn't always
# quit, so wait until the file is written in full, then close it. Each run gets its own profile.
chrome() {
  local out="$1" profile size
  shift
  profile="$(mktemp -d)"
  rm -f "$out"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check \
    --disable-extensions --disable-background-networking --disable-component-update \
    --user-data-dir="$profile" "$@" >/dev/null 2>&1 &
  local pid=$! waited=0
  while (( waited < 300 )); do
    if [[ -s "$out" ]]; then
      size=$(stat -f %z "$out"); sleep 0.5
      [[ $(stat -f %z "$out") == "$size" ]] && break
    fi
    sleep 0.2; (( waited += 1 ))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$profile"
}

for scale in 1 2; do
  name=background.png
  [[ $scale == 2 ]] && name=background@2x.png
  chrome "$OUT/$name" --window-size=640,470 --force-device-scale-factor=$scale --screenshot="$OUT/$name" "file://$PWD/background.html"
done

cp welcome-key.png welcome-allow.png "$OUT/guide/"
cp ../Resources/Fonts/*.ttf "$OUT/guide/"
cp "$ICON" "$OUT/guide/icon.png"
sed "s/__VERSION__/$VERSION/" "READ ME FIRST.html" > "$OUT/guide/guide.html"
chrome "$OUT/READ ME FIRST.pdf" --no-pdf-header-footer --print-to-pdf="$OUT/READ ME FIRST.pdf" "file://$OUT/guide/guide.html"

for f in background.png background@2x.png "READ ME FIRST.pdf"; do
  [[ -s "$OUT/$f" ]] || { echo "make.sh: $f wasn't made" >&2; exit 1; }
done
