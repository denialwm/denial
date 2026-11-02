# Hardware wake gestures

A touch controller's double tap reaches Denial as KEY_WAKEUP (143) through
libinput, from any input device. It needs no configuration: a kernel driver
that reports its wake gesture as KEY_WAKEUP is enough.

KEY_WAKEUP lights the built-in panel (the first `DSI-`, `eDP-` or `LVDS-`
output) through the existing lock-frame and KMS policy, or replaces a
fingerprint-only ambient scene with ordinary locked UI. It also counts as a
key press, so every other dark display wakes as it would for any key. Beside
a desk, where other keys leave the phone's panel dark, KEY_WAKEUP still
lights it. An awake panel stays awake. The key never reaches a client and
never grants authentication.

The board's persistent platform setup must enable double-tap decoding in the
touch controller before the screen-off transition. Full system suspend wake
needs separate validation.

## Synaptics S3910 (aston, nx809j, pudding)

The `synaptics_tcm_gesture` input reports the double tap as KEY_WAKEUP. The
kernel follows the DRM panel: display-off enters S3910 wakeup-gesture mode
with the double-tap mask and screen-off TOUCH_HOLD; display-on restores
normal mode and screen-on TOUCH_HOLD. Each volatile setting is read back. FOD
down/up is reported as physical contact through the touchscreen node with
firmware coordinates; it does not emit a wake key or grant authentication.

The touchscreen SPI device exposes `gesture_state` counters and verified mode
state, and its `power/wakeup` controls system wake. A PM wake IRQ retains gesture
sleep across system suspend, without resetting the controller on wake. Physical
double-tap, FOD, and full system-suspend tests must be recorded separately from
ordinary screen-off testing.
