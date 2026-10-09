# Keyboard window resizing

These native shortcuts resize the focused window in stacking, dwindle, and
scrolling layouts:

| Default shortcut | Action | Effect |
| --- | --- | --- |
| `Super+Minus` | `resizeShrinkWidth` | Narrower |
| `Super+Equal` | `resizeGrowWidth` | Wider |
| `Super+Shift+Minus` | `resizeShrinkHeight` | Shorter |
| `Super+Shift+Equal` | `resizeGrowHeight` | Taller |
| Unbound | `resetWindowHeight` | Restore the default height for the current layout |
| Unbound | `resetWindowWidth` | Restore the default width for the current layout |

Change bindings or assign **Reset window height** / **Reset window width** in Settings → Shortcuts.
Holding a grow/shrink shortcut repeats at the configured keyboard repeat rate.
The key names refer to physical keys, as with Denial's other native shortcuts.
Shortcut schema version 10 adds these defaults to older configurations without
replacing custom bindings on the same keys. Removing a binding after migration
keeps it removed.

The default step is **2% of the focused window's output work area**, along the
axis being resized. To choose a different step, set `layout.keyboardResizeStep`
in `~/.config/denial/settings.json` (or `$XDG_CONFIG_HOME/denial/settings.json`):

```json
{
  "layout": {
    "keyboardResizeStep": "32px"
  }
}
```

Merge the property into the existing `layout` object. Accepted string values
are positive logical pixel amounts such as `"32"` or `"32px"` (up to 32768),
or percentages such as `"5%"` (up to 100%). Fractional values are allowed;
each resize is rounded to at least one logical pixel. Omitting the property
uses `"2%"`. Valid file edits are reloaded by the running session; the settings
control API can also update the property.

For floating windows, resizing keeps the top-left position and the other
dimension unchanged, and honors client minimum and maximum sizes. Reset height preserves horizontal
geometry, respects size limits, and is idempotent. Decorations and reserved
work-area space are excluded from the reset content height.

For dwindle tiles, resizing adjusts the nearest shared split on the requested
axis. The focused side grows or shrinks and its siblings receive the remaining
space. Manual resizing preserves the current split orientations. Reset height
restores an equal split at the nearest vertical boundary, subject to client
minimum sizes. An axis with no shared split already fills
its available space and does not resize.

For scrolling tiles, resizing adjusts the nearest internal split when present.
Otherwise, width changes the column width in horizontal scrolling, and height
changes its main-axis extent in vertical scrolling. Main-axis extents retain
their 25–100% limits; shared splits retain their existing 10–90% limits.
Client minima can require more space. At a size limit, repeated keys do not
spill into an outer split or accumulate hidden steps.

A **lone tile** can also be made shorter in horizontal scrolling (or narrower
in vertical scrolling), leaving unused space below it (or to its right).
It remains aligned to the work area's leading cross-axis edge. Its default is
still the full available cross-axis extent, subject to client size constraints.
Manual cross-axis sizing stores **logical pixels**, even when the resize step
is a percentage: changing the output work area does not scale the stored size.
The effective size is bounded by the available space and client minimum/maximum
hints; an impossible minimum takes precedence. Rotating the strip transfers the
same fixed extent from height to width or back.

`resetWindowHeight` equalizes the nearest vertical split; for a lone tile in
horizontal scrolling it clears the fixed height and restores automatic/full
height. In vertical scrolling it retains its existing main-axis behavior
(restoring the default 60% extent). `resetWindowWidth` is the physical-horizontal
counterpart: it restores automatic/full cross-axis width for a lone vertical-strip
tile, equalizes the nearest horizontal split, or restores the default 60% column
width in horizontal scrolling. Neither reset action has a default binding.
For floating windows, width reset preserves vertical geometry and restores the
work-area width, subject to client constraints.

For pointer resizing, a lone tile's bottom edge (horizontal strip) or right edge
(vertical strip) adjusts its cross-axis size. The leading cross-axis edge does
not move or resize it. Main-axis resizing and shared stacked-boundary resizing
keep their existing behavior. Both physical axes are available to the Super
pointer resize grab, including corner resizing.

Reordering an independent column in the same layout space retains its fixed
cross-axis size, as do ordinary layout reconciliation and maximize/unmaximize.
Moving an individual window to another workspace/output starts with automatic
cross-axis sizing. Grouping clears lone-tile overrides: stacked columns still
fill the cross axis using their shared split boundaries; ungrouped tiles start
full again. No fraction, hidden suspended group size, or disk persistence is
introduced.

Maximized or fullscreen clients, locked shell geometry, mobile sessions, and
windows undergoing an interactive grab are not resized. Local Flutter windows
use their normal native placement path; shell fullscreen remains protected.
Preset cycling is outside this version of the feature.
