#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
export_dir="$script_dir/exports"
mkdir -p "$export_dir"

for name in key-hub trust-link key-route; do
    rsvg-convert --width 18 --height 18 "$script_dir/$name.svg" --output "$export_dir/$name@1x.png"
    rsvg-convert --width 36 --height 36 "$script_dir/$name.svg" --output "$export_dir/$name@2x.png"
done

swift "$script_dir/render-review.swift" "$script_dir"
