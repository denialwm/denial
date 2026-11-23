#!/bin/bash
# niri-bench.sh RENDER_NODE: niri config for the bench, windows floating at Denial's spots and sizes.
# Noctalia asks for blur behind its bar itself (ext-background-effect).
# CX CY KX KY: floating positions relative to niri's working area (default 48/14, 96/62: Noctalia's bar takes 34 px at the top).
B=~/.cache/bench; C=~/.config/niri/config.kdl
cp $B/niri-config.kdl.orig $C
sed -i "s#^spawn-at-startup \"waybar\"#spawn-at-startup \"$B/noctalia.sh\"#" $C
cat >> $C <<K

// bench: same output, render GPU, and window sizes and spots as Denial's stacking layout
output "eDP-2" {
    mode "1920x1200@144.000"
    scale 1
}
debug {
    render-drm-device "$1"
}
// Blur behind every window, sampling what is under it (other windows too), as Denial's
// blur mode does for each window without a full opaque region. kitty draws at 40%
// background opacity; Chromium declares no opaque region.
window-rule {
    background-effect {
        blur true
        xray false
    }
}
window-rule {
    match app-id="^bench-video$"
    open-floating true
    default-column-width { fixed 1070; }
    default-window-height { fixed 660; }
    default-floating-position x=${CX:-48} y=${CY:-14} relative-to="top-left"
}
window-rule {
    match app-id="^kitty$"
    open-floating true
    default-column-width { fixed 700; }
    default-window-height { fixed 450; }
    default-floating-position x=${KX:-96} y=${KY:-62} relative-to="top-left"
}
K
niri validate -c $C 2>&1 | tail -1
