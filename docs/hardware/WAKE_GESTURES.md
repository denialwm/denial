# Hardware wake gestures

A root-owned `/etc/denial/wake-gesture.json` enables an optional evdev gesture
source for hardware-decoded input that libinput does not expose. See
`roadstr-wake-gesture.json` for the Moto Edge 70's `double-tap` input node,
BTN_TRIGGER_HAPPY6 (709) and DSI-1 output. Device discovery and gesture code are
profile data; the input/frame decoder and native display policy are shared.

Denial opens the exact input through libseat without grabbing it. A complete
press frame wakes the configured output through existing lock-frame and KMS
policy, or replaces a fingerprint-only ambient scene with ordinary locked UI.
An awake display stays awake. FOD pulses, single taps, autorepeat and dropped
frames do not wake. Neither the gesture nor the profile grants authentication.

The board's persistent platform setup must enable double-tap decoding in the
touch controller before the screen-off transition. On Roadstr, writing decimal
49 to `/sys/class/touchscreen/primary/gesture` enables double tap independently
of decimal 17 for FOD; both remain enabled. No new kernel is required for the
audited touch-fod1 drivers. Full system suspend wake needs separate validation.
