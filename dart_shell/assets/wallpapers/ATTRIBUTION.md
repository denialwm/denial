# Bundled wallpaper attribution

## Trails — Accent 9 Dark

`trails-h-accent-9-dark.png` is a modified copy of **Trails — Accent 9
Dark**, created by **Gixo (`GixoXYZ`)** for the KDE Plasma 6 wallpaper
competition.

- Upstream project:
  [GixoXYZ/Plasma6Wallpapers](https://github.com/GixoXYZ/Plasma6Wallpapers)
- Pinned upstream revision:
  [`9316bf561cf211b6c0ffcf4528ffb2da393f4350`](https://github.com/GixoXYZ/Plasma6Wallpapers/commit/9316bf561cf211b6c0ffcf4528ffb2da393f4350)
- Original image:
  [`Wallpapers/Revision 2/Trails/trails-h-accent-9-dark.png`](https://github.com/GixoXYZ/Plasma6Wallpapers/blob/9316bf561cf211b6c0ffcf4528ffb2da393f4350/Wallpapers/Revision%202/Trails/trails-h-accent-9-dark.png)
- Original SHA-256:
  `48f92bafcb4aecb6aa7d56a099147e4177c467d90abd3b3ebaca38b374c8559e`
- Bundled SHA-256:
  `0af62259add37e1015ee421fc807c97b793a4e20878f0e2af3d687b61be5898f`
- License:
  [Creative Commons Attribution-ShareAlike 4.0 International](https://creativecommons.org/licenses/by-sa/4.0/)

The upstream repository identifies its images as CC BY-SA 4.0. Denial
distributes this derivative under the same license. The complete license text
is in [`LICENSES/CC-BY-SA-4.0.txt`](../../../LICENSES/CC-BY-SA-4.0.txt).

### Denial modifications

On 2026-07-25, the Denial project resized the upstream 5120 × 2885 PNG to
2560 × 1440 using Lanczos resampling, applied a centered crop of the few excess
vertical pixels needed for an exact 16:9 frame, and removed embedded metadata.
No other visual changes were made.

The derivative can be reproduced with ImageMagick:

```sh
magick trails-h-accent-9-dark-original.png \
  -filter Lanczos \
  -resize '2560x1440^' \
  -gravity center \
  -extent 2560x1440 \
  -strip \
  -define png:compression-level=9 \
  trails-h-accent-9-dark.png
```
