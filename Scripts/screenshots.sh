#!/bin/bash
# Build a made-up folder tree and render the README pictures from it.
#
#     Scripts/screenshots.sh            # tree + pictures into docs/images/ (+ web/)
#     Scripts/screenshots.sh --tree     # only (re)build the sample tree
#     Scripts/screenshots.sh --clean    # delete the sample tree
#
# The pictures never show a real disk: every folder and file name below is
# invented, so they can be published as they are. The tree lives in
# /Users/Shared/Sample, a path that names no user, because the pictures show
# it. It costs about 2 GB of real disk, though it reports
# far more: files are APFS clones of one random block, truncated to distinct
# sizes, so their contents differ and only the intended pairs are duplicates.
#
# Rendering uses the app's offscreen mode (DISKMAP_RENDER, see README) with
# DISKMAP_RENDER_WINDOW=1, so buttons and pickers are drawn as they look in the
# app. No Screen Recording permission is needed. Build first:
# Scripts/build-app.sh. The website copies need ImageMagick (brew install
# imagemagick).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="/Users/Shared/Sample"
APP="build/DiskMap.app/Contents/MacOS/DiskMap"
OUT="docs/images"

if [ "${1:-}" = "--help" ]; then sed -n 2,19p "$0"; exit 0; fi
if [ "${1:-}" = "--clean" ]; then rm -rf "$ROOT" tmp/sample-base.bin; exit 0; fi

# One random block to clone from. 2 GiB covers the largest file below.
BASE="$PWD/tmp/sample-base.bin"
if [ ! -f "$BASE" ]; then
  mkdir -p tmp
  head -c $((2048 * 1024 * 1024)) /dev/urandom > "$BASE"
fi

N=0
# f <path> <size in KiB> [age in days]: a clone of the base, cut to size.
# N nudges every size by a few KiB so no two files match by accident.
f() {
  local p="$ROOT/$1" kib=$(( $2 + N % 97 )) days="${3:-30}"
  N=$((N + 1))
  mkdir -p "$(dirname "$p")"
  cp -c "$BASE" "$p"
  truncate -s $((kib * 1024)) "$p"
  touch -t "$(date -v-"${days}"d +%Y%m%d%H%M)" "$p"
}
# many <dir> <count> <ext> <min KiB> <max KiB> <max age>: a folder of similar files.
many() {
  local i
  for i in $(seq -w 1 "$2"); do
    f "$1/$(basename "$1")-$i.$3" $(( $4 + RANDOM % ($5 - $4 + 1) )) $(( RANDOM % $6 + 1 ))
  done
}

build_tree() {
  rm -rf "$ROOT"
  # Photos: many mid-sized files, three years apart
  many "Pictures/Photos/2024" 140 heic 1800 4200 700
  many "Pictures/Photos/2025" 180 heic 1800 4600 360
  many "Pictures/Photos/2026" 90 heic 2000 5200 200
  many "Pictures/Edits" 24 tif 18000 42000 400
  # Video: a few very large files
  f "Movies/Trips/coast-2025.mov" 1800000 380
  f "Movies/Trips/mountains-2026.mov" 1350000 120
  f "Movies/Drone/lake-4k.mp4" 920000 60
  f "Movies/Drone/valley-4k.mp4" 610000 58
  f "Movies/Screen recordings/demo-take-3.mov" 240000 12
  # Music
  many "Music/Library/Albums" 160 m4a 6000 12000 1500
  # Code: a project with a heavy node_modules and build output
  many "Developer/web-shop/node_modules/.pnpm" 400 js 8 380 90
  many "Developer/web-shop/node_modules/.cache" 30 bin 2000 9000 20
  many "Developer/web-shop/src" 60 ts 2 40 10
  f "Developer/web-shop/build/bundle.js" 3400 2
  many "Developer/game/Assets/Textures" 70 png 800 6000 200
  f "Developer/game/Build/game-arm64.app.zip" 480000 30
  f "Developer/vm/ubuntu-24.04.qcow2" 2000000 90
  # Downloads: installers and archives, one of them downloaded twice
  f "Downloads/Xcode-installer.xip" 1200000 200
  f "Downloads/photo-editor-2.4.dmg" 310000 40
  f "Downloads/fonts.zip" 42000 300
  many "Downloads/papers" 36 pdf 400 9000 600
  f "Documents/Taxes/2025/receipts.zip" 88000 250
  many "Documents/Reports" 40 pdf 120 5000 900
  many "Documents/Slides" 18 key 9000 60000 500
  f "Archive/backup-2023.tar.gz" 1500000 900
  f "Archive/old-laptop.sparsebundle.zip" 900000 1100
  # Two genuine duplicates, so the Copies panel has something to show. Files
  # match on name and size, so each copy keeps its original's name.
  cp -c "$ROOT/Downloads/photo-editor-2.4.dmg" "$ROOT/Archive/photo-editor-2.4.dmg"
  cp -c "$ROOT/Movies/Drone/lake-4k.mp4" "$ROOT/Pictures/Edits/lake-4k.mp4"
  echo "sample tree: $(du -sh "$ROOT" | cut -f1) reported by du, in $ROOT"
}

# shot <name> <w> <h> <theme> <lang> [subdir] [env...]
shot() {
  local name="$1" w="$2" h="$3" theme="$4" lang="$5" sub="${6:-}"
  shift 6 2>/dev/null || shift $#
  env "$@" DISKMAP_RENDER_WINDOW=1 DISKMAP_RENDER="$ROOT|$w|$h|$PWD/$OUT/$name.png|$sub|$theme|$lang" "$APP" >/dev/null
  echo "$OUT/$name.png"
}

[ -d "$ROOT" ] && [ "${1:-}" != "--tree" ] || build_tree
[ "${1:-}" = "--tree" ] && exit 0
[ -x "$APP" ] || { echo "no $APP: run Scripts/build-app.sh first" >&2; exit 1; }
mkdir -p "$OUT"
shot treemap-light     1440 900 light en ""
shot treemap-dark      1440 900 dark  en ""
shot sunburst-dark     1440 900 dark  en "" DISKMAP_VIEW=sunburst
shot age-light         1440 900 light en "" DISKMAP_COLOUR=age
shot duplicates-light  1440 900 light en "" DISKMAP_PANEL=duplicates DISKMAP_EXPAND=1
shot treemap-tr-light  1440 900 light tr ""

# The README shows the PNGs; the website loads these, a quarter of the bytes.
command -v magick >/dev/null || { echo "no ImageMagick: web copies not made" >&2; exit 1; }
mkdir -p "$OUT/web"
for p in "$OUT"/*.png; do
  magick "$p" -resize 1920x -quality 84 "$OUT/web/$(basename "${p%.png}").jpg"
done
du -sh "$OUT" "$OUT/web"
