# Android recents reference

The reference for the mobile overview refinements is AOSP tag
`android-16.0.0_r1`. Modern Android connects SystemUI to Launcher3 Quickstep,
where the task overview and its gestures are implemented.

| Responsibility | Android source |
| --- | --- |
| SystemUI / launcher connection | [OverviewProxyService.java](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/packages/SystemUI/src/com/android/systemui/recents/OverviewProxyService.java) |
| Task list, selection, removal, launch transitions | [RecentsView.java](https://android.googlesource.com/platform/packages/apps/Launcher3/+/refs/tags/android-16.0.0_r1/quickstep/src/com/android/quickstep/views/RecentsView.java) |
| Dismiss direction, threshold, resistance | [TaskViewDismissTouchController.kt](https://android.googlesource.com/platform/packages/apps/Launcher3/+/refs/tags/android-16.0.0_r1/quickstep/src/com/android/launcher3/uioverrides/touchcontrollers/TaskViewDismissTouchController.kt) |
| Spring settling and neighboring task reflow | [RecentsDismissUtils.kt](https://android.googlesource.com/platform/packages/apps/Launcher3/+/refs/tags/android-16.0.0_r1/quickstep/src/com/android/quickstep/views/RecentsDismissUtils.kt) |
| Preview scale, page spacing, undershoot | [Quickstep dimensions](https://android.googlesource.com/platform/packages/apps/Launcher3/+/refs/tags/android-16.0.0_r1/quickstep/res/values/dimens.xml) |
| Fling release velocity | [Launcher dimensions](https://android.googlesource.com/platform/packages/apps/Launcher3/+/refs/tags/android-16.0.0_r1/res/values/dimens.xml) |

Denial applies the following behavior in `dart_shell/lib/src/widgets/overview/`:

- Portrait previews fit within 70% of the view, respect insets, and keep a
  fixed 16 logical pixel gap. The page stride and entry hero use the same
  geometry. Changing the viewport preserves the selected page.
- The current app leads the carousel, with older previews to its left.
  Selecting a preview slides its neighbors outward in time with the selected
  app's zoom, retaining their size and live content throughout the motion.
- Previews have no visible app-name labels; app names remain available to
  accessibility services. The lighter background dimming fades out during
  app selection, including behind transparent windows.
- Horizontal flings coast with clamped Android scroll physics across as many
  tasks as their momentum carries them, then center the nearest preview.
- An upward fling above 1000 logical pixels/second dismisses a task. A slow
  drag must exceed half the distance needed to move the entire preview
  offscreen. A downward fling cancels even beyond that threshold.
- Downward travel meets progressive resistance capped at 25 logical pixels.
  Raw finger displacement is retained so reversing the drag unwinds smoothly.
  Cancelled pointer streams return the card without requesting a close.
- Settling uses Denial's velocity-seeded springs. A close request is sent once,
  after the offscreen frame. The carousel then closes the gap in 300ms while
  preserving the selected task by identity, or choosing the next task (the
  previous task at the end of the list).
- Delayed client acknowledgments and unrelated window snapshots do not
  resurrect a dismissed card. Batched removals resolve directly to a surviving
  task. A viewport extended by one page on each side keeps translated
  neighbors paintable; the visible carousel remains clipped to the screen.

These are Flutter implementations using Denial's retained live Wayland
textures and existing springs. Android's exact spring tuning, expressive
scale feedback, swipe-down launch, task menus, and two-row tablet overview
are not implemented by this change. Denial's existing landscape grid and
foreground hero interaction remain in place.

Headless regression tests:

```sh
tools/denial-pc flutter-test --no-pub test/widgets/overview/overview_carousel_test.dart
```

The tests cover geometry, gesture outcomes, pointer cancellation, retained
previews, focus transitions, and reflow. Visual validation belongs to the user.
