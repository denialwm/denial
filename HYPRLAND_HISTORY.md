# Hyprland history and upstream policy

`Hyprland/` is ordinary source owned by the Denial repository. It is not a
submodule and it has no nested Git repository. Changes that cross the Dart
shell, native embedder, protocol, and compositor belong in one Denial commit.

## Imported history

The monorepo import joins the original Denial root history with the complete
Hyprland history. Its second parent is the unmodified customized Hyprland tip:

- customized import: `6599efeddc212be93795355c2ba4963f7e850c2d`
- upstream base: `v0.55.4` at
  `a0136d8c04687bb36eb8a28eb9d1ff92aea99704`
- namespaced references: `hyprland/import-2026-07-16` and
  `hyprland/upstream-v0.55.4`

The original commit IDs, authors, messages, and upstream ancestry remain
valid. `git blame Hyprland/<path>` follows the pre-import commits normally.
For a path-oriented log across the repository-boundary merge, use:

```sh
git log --full-history -m --follow -- Hyprland/<path>
```

## Upstream updates

Upstream changes are deliberate, reviewed imports rather than automatic
submodule movement:

1. Create and verify a persistent bundle before changing the imported tree.
2. Fetch the intended official Hyprland revision into a namespaced reference.
3. Perform a non-squashed subtree-style merge under `Hyprland/`, preserving
   upstream commit ancestry.
4. Reconcile Denial's pinned external dependency revisions if Hyprland changes
   its protocol or disassembler requirements.
5. Build Denial and commit any cross-layer adaptation in the main repository.

Hyprland's required third-party source is bootstrapped outside the checkout by
`tools/denial-pc`; the Denial repository contains no gitlinks.
