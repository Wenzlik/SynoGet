#!/bin/sh
# Requires the development-only librsvg CLI (brew install librsvg).
set -eu
cd "$(dirname "$0")/.."
assets=DropStation/Resources/Assets.xcassets
rsvg-convert icon.svg -o "$assets/AppIcon.appiconset/AppIcon-1024.png"
rsvg-convert icon-dark.svg -o "$assets/AppIcon.appiconset/AppIcon-Dark-1024.png"
rsvg-convert icon-tinted.svg -o "$assets/AppIcon.appiconset/AppIcon-Tinted-1024.png"
rsvg-convert -w 264 -h 264 icon.svg -o "$assets/BrandIcon.imageset/BrandIcon.png"
rsvg-convert -w 264 -h 264 icon-dark.svg -o "$assets/BrandIcon.imageset/BrandIcon-Dark.png"
