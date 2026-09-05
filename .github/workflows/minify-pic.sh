#!/usr/bin/env bash
# Batch-minify raster logos in a directory (SVG/ICO are left untouched).
#
# Usage: minify-pic.sh [dir] [width]
#   dir    default ./assets/image/logo
#   width  max width in px, default 64. Always shrink-only: the '>' modifier
#          is appended automatically (images narrower than the limit are
#          never upscaled).
#
# Per file: read the first-frame width via identify; only when it exceeds the
# limit, mogrify -resize "${width}x>" (jpg/webp also get -quality 82); pngs
# are then quantized with pngquant --skip-if-larger (skipped with a warning
# if pngquant is not installed, e.g. on CI runners without apt packages).

set -euo pipefail
shopt -s nullglob

dir="${1:-./assets/image/logo}"
width="${2:-64}"
width="${width%x}"   # tolerate callers passing "64x" style args
extra_args=()

echo "minify-pic: dir=$dir width=${width}x (shrink-only)"

if ! command -v identify >/dev/null 2>&1 || ! command -v mogrify >/dev/null 2>&1; then
  echo "WARNING: ImageMagick (identify/mogrify) not found, nothing to do." >&2
  exit 0
fi

if command -v pngquant >/dev/null 2>&1; then
  have_pngquant=1
else
  have_pngquant=0
  echo "WARNING: pngquant not found, skipping png quantization step." >&2
fi

for file in "$dir"/*.{jpg,jpeg,png,webp}; do
  # first frame only: animated files (webp/ico-style) repeat %w per frame,
  # so terminate each value with \n and keep the first line
  w=$(identify -format '%w\n' "$file" | head -1)
  if [ -z "$w" ] || [ "$w" -le "$width" ]; then
    continue
  fi

  case "$file" in
    *.png)
      extra_args=()
      ;;
    *.jpg|*.jpeg|*.webp)
      extra_args=(-quality 82)
      ;;
    *)
      continue
      ;;
  esac

  echo "shrink $file (${w}px > ${width}px)"
  # guard for bash <4.4 with `set -u`: "${arr[@]}" on an empty array is an error
  if [ "${#extra_args[@]}" -gt 0 ]; then
    mogrify -resize "${width}x>" "${extra_args[@]}" "$file"
  else
    mogrify -resize "${width}x>" "$file"
  fi

  if [ "${have_pngquant}" -eq 1 ]; then
    case "$file" in
      *.png)
        pngquant --skip-if-larger --force --ext .png "$file" || {
          rc=$?
          # rc 98/99: quantized result would be larger, original kept
          if [ "$rc" -ne 98 ] && [ "$rc" -ne 99 ]; then
            echo "WARNING: pngquant failed on $file (rc=$rc)" >&2
          fi
        }
        ;;
    esac
  fi
done

echo "minify-pic: done"
