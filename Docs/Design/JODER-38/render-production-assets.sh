#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
root_dir="${script_dir:h:h:h}"
source_icon="$script_dir/keyport-app-icon-source.png"
menu_svg="$script_dir/keyport-menu-template.svg"
resource_dir="$root_dir/Resources"
iconset_dir="$script_dir/build/KeyPort.iconset"

for tool in sips iconutil rsvg-convert; do
    command -v "$tool" >/dev/null || {
        print -u2 "Missing required tool: $tool"
        exit 1
    }
done

mkdir -p "$iconset_dir" "$resource_dir" "$script_dir/exports"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$source_icon" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$source_icon" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil --convert icns --output "$resource_dir/KeyPort.icns" "$iconset_dir"

rsvg-convert --width 18 --height 18 "$menu_svg" --output "$resource_dir/KeyPortMenuTemplate.png"
rsvg-convert --width 36 --height 36 "$menu_svg" --output "$resource_dir/KeyPortMenuTemplate@2x.png"
cp "$menu_svg" "$resource_dir/KeyPortMenuTemplate.svg"

cp "$resource_dir/KeyPortMenuTemplate.png" "$script_dir/exports/keyport-menu-template@1x.png"
cp "$resource_dir/KeyPortMenuTemplate@2x.png" "$script_dir/exports/keyport-menu-template@2x.png"

swift "$script_dir/render-production-review.swift" "$script_dir"

print "Generated Resources/KeyPort.icns and KeyPortMenuTemplate resources"
