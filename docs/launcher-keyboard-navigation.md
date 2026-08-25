# Launcher keyboard navigation

The desktop application launcher supports keyboard-first operation while its
search field retains text-input focus.

## Behavior

| Input | Action |
| --- | --- |
| Left / Right | Move to the previous / next result, crossing row boundaries |
| Up / Down | Move by row, preserving the column where possible |
| Tab / Shift+Tab | Move to the next / previous result |
| Enter | Launch the selected result |
| Escape | Dismiss immediately and release shell keyboard capture |
| Click outside | Dismiss the launcher and consume that click |

The first visible result is selected by default. A query change resets the
selection and scroll position to the first filtered result. Selection is stored
by a namespaced application identity, so provider updates and identical local
and desktop application IDs cannot redirect Enter to a different item.

## Input routing

When the launcher opens, its dismiss barrier publishes a full-scene pointer
region. This is necessary because Denial normally excludes client-window
regions from Flutter pointer routing. The first outside click therefore reaches
the shell, closes the launcher, unfocuses the search field, and releases the
panel's keyboard capture instead of leaking through to a client.

The full-scene region is active only while the launcher is open. The launcher
panel remains above the barrier in the scene, so clicks on launcher controls
continue to reach those controls.

## Keyboard and text-input separation

`CallbackShortcuts` is placed between the application-level shortcuts and the
search `EditableText`. It consumes launcher navigation keys before Flutter's
default text-editing and focus-traversal shortcuts.

Enter continues through `EditableText.onSubmitted`, preserving the normal IME
submission path. Escape uses the launcher's required immediate-dismiss callback;
it never falls back to the delayed hover-exit callback.

Raw key events and IME text commits are separate channels. As a final safeguard,
the search field rejects C0 and DEL control characters if an input method tries
to commit them as text. Normal Unicode text, including composed and non-Latin
input, remains accepted.

## Navigation geometry

Grid navigation and automatic scrolling share the tile extent and spacing
constants used by `SliverGridDelegateWithMaxCrossAxisExtent`. Vertical movement
clamps to the nearest valid column on an incomplete final row. Automatic scroll
respects the system's reduced-motion setting.

## Validation

Focused widget coverage includes:

- mouse launch behavior;
- navigation with and without a query;
- Tab and Shift+Tab cycling;
- immediate Escape dismissal;
- IME control-character filtering;
- horizontal wrapping and incomplete-row vertical movement;
- focus changes that must not reset selection; and
- automatic scrolling to off-screen selections.

Run the focused suite with the repository's locked Flutter test toolchain, then
build and refresh the live bundle with:

```sh
tools/denial-pc bundle
tools/denial-pc refresh
```
