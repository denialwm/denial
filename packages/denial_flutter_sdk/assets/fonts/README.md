# JetBrains Mono font assets

Denial bundles the regular, medium, and bold static TTFs from
[JetBrains Mono 2.304](https://github.com/JetBrains/JetBrainsMono/releases/tag/v2.304).
The files and `OFL.txt` are byte-identical to those in the official
`JetBrainsMono-2.304.zip` release archive.

- Release archive SHA-256:
  `6f6376c6ed2960ea8a963cd7387ec9d76e3f629125bc33d1fdcd7eb7012f7bbf`
- License: SIL Open Font License 1.1
- Upstream project:
  [JetBrains/JetBrainsMono](https://github.com/JetBrains/JetBrainsMono)

Verify the retained files from this directory with:

```sh
sha256sum --check --strict JetBrainsMono.sha256
```

Denial's Linux engine scans `/usr/share/fonts` recursively. Its directory font
manager can match named families but cannot discover a family from a missing
character, so `ShellText.fallbackFontFamilies` explicitly requests Source Han
Sans CN and then Noto Sans CJK SC. The Arch package depends on Source Han Sans
CN so the Simplified Chinese shell catalog has a deterministic fallback even
on a minimal installation.

# Roboto Flex font asset

`roboto_flex/` holds the Roboto Flex 3.200 variable TTF, which the clock uses
when it stretches the time: its width and weight axes keep a taller time at
the plain time's width and stroke. `RobotoFlex.ttf` and `OFL.txt` are
byte-identical to `ofl/robotoflex/` in
[google/fonts](https://github.com/google/fonts/tree/8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5/ofl/robotoflex)
at commit `8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5`, where the font is named
`RobotoFlex[GRAD,XOPQ,XTRA,YOPQ,YTAS,YTDE,YTFI,YTLC,YTUC,opsz,slnt,wdth,wght].ttf`.

- License: SIL Open Font License 1.1
- Upstream project:
  [googlefonts/roboto-flex](https://github.com/googlefonts/roboto-flex)

Verify the retained files from `roboto_flex/` with:

```sh
sha256sum --check --strict RobotoFlex.sha256
```
