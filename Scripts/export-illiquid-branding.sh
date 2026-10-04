#!/bin/bash
# Export the selected Smooth prism identity without rebuilding the app.
set -euo pipefail
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
asset_root="$repository_root/Resources/Branding/SmoothPrism"
export_root="$asset_root/Exports"
mkdir -p "$export_root/AppIcon.iconset"
sips -s format png -z 1024 1024 "$repository_root/Resources/IlliquidIcon.png" \
    --out "$export_root/app-icon.png" >/dev/null
for source in "$asset_root"/*.svg; do
    filename="$(basename "$source" .svg)"
    sips -s format png "$source" --out "$export_root/$filename.png" >/dev/null
done
for entry in \
    '16 icon_16x16.png' '32 icon_16x16@2x.png' \
    '32 icon_32x32.png' '64 icon_32x32@2x.png' \
    '128 icon_128x128.png' '256 icon_128x128@2x.png' \
    '256 icon_256x256.png' '512 icon_256x256@2x.png' \
    '512 icon_512x512.png' '1024 icon_512x512@2x.png'; do
    read -r size filename <<< "$entry"
    sips -z "$size" "$size" "$export_root/app-icon.png" \
        --out "$export_root/AppIcon.iconset/$filename" >/dev/null
done
iconutil -c icns "$export_root/AppIcon.iconset" -o "$export_root/AppIcon.icns"
mkdir -p "$export_root/VideoDocument.iconset"
for icon in "$export_root/AppIcon.iconset"/*.png; do
    size=$(sips -g pixelWidth "$icon" | awk '/pixelWidth/ {print $2}')
    sips -z "$size" "$size" "$export_root/video-document.png" \
        --out "$export_root/VideoDocument.iconset/$(basename "$icon")" >/dev/null
done
iconutil -c icns "$export_root/VideoDocument.iconset" -o "$export_root/VideoDocument.icns"
printf 'Exported Illiquid branding to %s\n' "$export_root"
