# Known issues

## X11 windows require Denial decorations

With Impeller blur enabled, minimizing a managed X11/Xwayland window that
bypasses Denial's server-side decorations can corrupt blur and render displaced
duplicate shadows on other windows. Normal managed X11 toplevels must therefore
keep Denial's decorations, including its rounded corners and shadows; only
popup-like and override-redirect surfaces should remain undecorated.

Denial currently mitigates the issue by ignoring client decoration opt-outs.
The underlying Impeller rendering defect remains unresolved.
