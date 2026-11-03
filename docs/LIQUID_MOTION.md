# Liquid motion

The recipe behind the phone's volume indicator
(`plugins/denial_desktop/lib/src/widgets/mobile_volume_hud.dart`). The user
asked for it to be reused, so new mobile controls that appear, hold a value
or follow a finger start from here.

## Principles

1. **Springs, never durations.** Every moving quantity is a damped spring
   with a target. A new event retargets it and keeps its velocity, so rapid
   key presses blend into one motion instead of restarting.
2. **Things are born and die as a bead.** The control enters as a small
   round bead from the edge it belongs to, then stretches into its shape. It
   leaves in reverse: it shrinks back into the bead first, then the bead
   slides away. Contents appear only once the shape has formed and go first.
3. **Values are liquid.** A fill pours from the old value to the new one. Its
   surface lags the motion: it bulges while it moves, then rings a few times
   and settles flat.
4. **Every input tugs the body.** A step stretches the control toward the
   change and lets it spring back (squash and stretch, with the width
   thinning as it stretches). A step against the end of the range tugs
   harder and rings.
5. **The finger is direct.** While a finger holds the control, values are
   set from the finger, never chased by a spring: restarting a spring on
   every touch sample makes it lag. No slop: it moves on the first
   sample. Springs take over at release, with the finger's velocity. Past
   either end the body stretches like rubber, gives one haptic pulse,
   and springs back on release.
6. **Holding shows.** Under the finger the control widens a little and its
   rim brightens.
7. **No opacity layers.** Fades multiply paint colours. Text that would sit
   on the fill is painted twice, in ink over the background and in the
   background's colour clipped to the fill.

## Structure

- One `ChangeNotifier` owns all springs and one `Ticker`. The ticker starts
  on any event and stops itself when every spring rests.
- Painters take the notifier as `repaint:`. Per-frame values never go into
  Riverpod or widget state; widgets rebuild only on show and gone.
- Springs are stepped with semi-implicit Euler in sub-steps of at most
  1/480 s, so stiff springs stay stable at any refresh rate. Frame `dt` is
  clamped to 1/30 s.
- The touch area is the resting shape, slightly inflated, and never moves
  with the animation: the input layout is published once on show.
- Reduced motion settles every spring at once.
- Text is laid out once per value and colour and cached.

## Tuning

Stiffness k, damping ratio ζ.

| Spring | k | ζ | Role |
|---|---|---|---|
| slide in | 520 | 0.74 | from the edge, small overshoot |
| grow in | 230 | 0.6 | bead to shape, about 10% overshoot |
| grow out | 420 | 1 | shape back to bead, quickly |
| slide out | 150 | 1 | slower than grow out, so the bead forms first |
| level | 300 | 0.8 | the pour |
| surface | 340 | 0.2 | the slosh; rings several times |
| stretch | 520 | 0.42 | squash and stretch |
| grab | 620 | 0.82 | widen under the finger |
| mute | 420 | 0.9 | strike-through and dimmed fill |

- **Surface target:** level speed in px/s × 0.05, clamped to ±14 px. Upward
  motion makes the middle lead. A tilt ripple of 0.4 × the bulge at
  sin(26 t) rides on it.
- **Stretch kick:** velocity += 240 px/s per step toward the change, or
  520 px/s at a range end.
- **Rubber band:** pull p px past the end gives 28 × (1 − 1/(1 + |p|/60)) px.
- **Finger velocity:** blended 0.6 old + 0.4 new per sample. It decays with
  pow(0.02, dt) while the finger rests, so the surface rings when it stops.
- **Bead:** starts at 66% of the resting width.
- **Grab:** +14% width.
- **Stretch thinning:** −3% width per 10 px of stretch, up to 4.5%.
- **Contents:** smoothstep of grow over 0.55..0.95.
- **Glyph detail:** speaker waves come in at levels 0.01, 0.34 and 0.67,
  each over ±0.06, swinging open from its middle.
- **Hide:** 1.5 s after the last change or after the finger lifts.
