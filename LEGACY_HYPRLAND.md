# Legacy Hyprland reference

Denial's last known-good Hyprland-based implementation is frozen at the
annotated Git tag `hyprland-last-known-good`. It is a regression reference,
not a maintained alternative implementation. `main` contains only the Rust
compositor.

Create a separate checkout when a behavior needs comparison:

```sh
git worktree add ../denial-hyprland-reference hyprland-last-known-good
```

The worktree contains the complete historical native source, C++ protocol
tests and benchmarks, dependency patches, build tooling and documentation.
Changes discovered while investigating a regression should normally become a
test or fix on the Rust implementation rather than updates to the legacy tag.

The tag points to commit `f78be63d4dd84466d978518797090fdb1ee75a96`
(`Initial commit`).
