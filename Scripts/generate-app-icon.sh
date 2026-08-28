#!/bin/bash
#
# Generates every macOS app-icon size Xcode expects, from a single square master
# image, and rewrites AppIcon.appiconset/Contents.json to match.
#
# Usage:
#   Scripts/generate-app-icon.sh [path/to/master.png]
#
# With no argument the script picks up the image already dropped into
# Shelfer/Assets.xcassets/AppIcon.appiconset (largest one wins), so re-running it
# after a fresh drag-and-drop in Xcode is safe.
#
# Requires: sips (ships with macOS).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICONSET="$REPO_ROOT/Shelfer/Assets.xcassets/AppIcon.appiconset"

# pixel size : filename — the ten slots a macOS app icon set declares.
SPECS=(
  "16:icon_16x16.png"
  "32:icon_16x16@2x.png"
  "32:icon_32x32.png"
  "64:icon_32x32@2x.png"
  "128:icon_128x128.png"
  "256:icon_128x128@2x.png"
  "256:icon_256x256.png"
  "512:icon_256x256@2x.png"
  "512:icon_512x512.png"
  "1024:icon_512x512@2x.png"
)

# The 1024pt slot doubles as the master when the script is re-run.
MASTER_SLOT="icon_512x512@2x.png"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
fi

command -v sips >/dev/null 2>&1 || {
  echo "error: sips not found — this script needs to run on macOS." >&2
  exit 1
}

is_generated() {
  local name="$1"
  for spec in "${SPECS[@]}"; do
    [[ "$name" == "${spec#*:}" ]] && return 0
  done
  return 1
}

pixel_width() {
  sips -g pixelWidth "$1" 2>/dev/null | awk '/pixelWidth:/ { print $2 }'
}

pixel_height() {
  sips -g pixelHeight "$1" 2>/dev/null | awk '/pixelHeight:/ { print $2 }'
}

# --- locate the master image -------------------------------------------------

MASTER="${1:-}"

if [[ -z "$MASTER" ]]; then
  best=""
  best_px=0
  shopt -s nullglob
  for candidate in "$ICONSET"/*.png "$ICONSET"/*.PNG; do
    is_generated "$(basename "$candidate")" && continue
    px="$(pixel_width "$candidate")"
    [[ -z "$px" ]] && continue
    if (( px > best_px )); then
      best_px="$px"
      best="$candidate"
    fi
  done
  shopt -u nullglob

  # Nothing new dropped in? Fall back to the largest slot we generated before.
  if [[ -z "$best" && -f "$ICONSET/$MASTER_SLOT" ]]; then
    best="$ICONSET/$MASTER_SLOT"
  fi
  MASTER="$best"
fi

if [[ -z "$MASTER" || ! -f "$MASTER" ]]; then
  cat >&2 <<'MSG'
error: no source image found.

Pass one explicitly:

    Scripts/generate-app-icon.sh ~/Desktop/shelfer-icon.png

or drop a 1024x1024 PNG into Shelfer/Assets.xcassets/AppIcon.appiconset
and run this script again with no arguments.
MSG
  exit 1
fi

# --- validate ----------------------------------------------------------------

width="$(pixel_width "$MASTER")"
height="$(pixel_height "$MASTER")"

if [[ -z "$width" || -z "$height" ]]; then
  echo "error: could not read image dimensions from $MASTER" >&2
  exit 1
fi

echo "master: $MASTER (${width}x${height})"

if (( width != height )); then
  cat >&2 <<MSG
error: the app icon must be square, but this image is ${width}x${height}.
Export it as a square canvas (1024x1024) and run the script again.
MSG
  exit 1
fi

if (( width < 1024 )); then
  echo "warning: master is only ${width}x${width}; the 1024pt slot will be upscaled and look soft." >&2
  echo "         Export a 1024x1024 master for a clean result." >&2
elif (( width > 1024 )); then
  echo "note: master is larger than 1024x1024; it will be downscaled to fit every slot."
fi

# --- generate ----------------------------------------------------------------

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Copy first: the master often lives inside the icon set we are about to clean.
cp "$MASTER" "$TMP_DIR/master.png"

shopt -s nullglob
for stale in "$ICONSET"/*.png "$ICONSET"/*.PNG "$ICONSET"/*.jpg "$ICONSET"/*.jpeg; do
  rm -f "$stale"
done
shopt -u nullglob

for spec in "${SPECS[@]}"; do
  px="${spec%%:*}"
  name="${spec#*:}"
  sips -s format png -z "$px" "$px" "$TMP_DIR/master.png" --out "$ICONSET/$name" >/dev/null
  echo "  wrote $name (${px}x${px})"
done

# --- rewrite Contents.json ---------------------------------------------------

{
  echo '{'
  echo '  "images" : ['
  entries=()
  for spec in "${SPECS[@]}"; do
    px="${spec%%:*}"
    name="${spec#*:}"
    if [[ "$name" == *"@2x"* ]]; then
      scale="2x"
      pt=$(( px / 2 ))
    else
      scale="1x"
      pt="$px"
    fi
    entries+=("    {
      \"filename\" : \"${name}\",
      \"idiom\" : \"mac\",
      \"scale\" : \"${scale}\",
      \"size\" : \"${pt}x${pt}\"
    }")
  done
  printf '%s' "${entries[0]}"
  for (( i = 1; i < ${#entries[@]}; i++ )); do
    printf ',\n%s' "${entries[$i]}"
  done
  printf '\n'
  echo '  ],'
  echo '  "info" : {'
  echo '    "author" : "xcode",'
  echo '    "version" : 1'
  echo '  }'
  echo '}'
} > "$ICONSET/Contents.json"

echo "updated $ICONSET/Contents.json"
echo "done — clean the build folder (Shift-Cmd-K) and rebuild."
