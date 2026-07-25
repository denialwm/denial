# Clipboard image fixture

`clipboard_screenshot.jpg` is an original synthetic test image made only from
geometric primitives. It exercises JPEG decoding and clipboard-preview layout
without embedding third-party artwork.

Regenerate it with ImageMagick:

```sh
magick -size 320x189 "gradient:#172235-#31566b" \
  -fill "#735d9a" -draw "roundrectangle 28,26 224,155 18,18" \
  -fill "#1c2937" -draw "roundrectangle 42,43 210,139 12,12" \
  -fill "#84dbff" -draw "circle 78,72 88,72" \
  -fill "#c7d1dc" -draw "roundrectangle 101,65 187,73 4,4" \
  -fill "#526a7c" -draw "roundrectangle 61,96 190,105 4,4" \
  -fill "#526a7c" -draw "roundrectangle 61,116 161,125 4,4" \
  -strip -quality 85 clipboard_screenshot.jpg
```
