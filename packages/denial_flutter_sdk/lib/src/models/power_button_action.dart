enum PowerButtonAction { suspend, hibernate, dpms, powerOff }

extension PowerButtonActionWireValue on PowerButtonAction {
  int get wireValue => switch (this) {
    PowerButtonAction.dpms => 0,
    PowerButtonAction.suspend => 1,
    PowerButtonAction.hibernate => 2,
    PowerButtonAction.powerOff => 3,
  };
}

/// What holding the power button does on the desktop. The mobile shell always
/// opens the power menu.
enum PowerButtonLongPressAction {
  nothing,
  powerMenu,
  suspend,
  hibernate,
  powerOff,
}

extension PowerButtonLongPressActionWireValue on PowerButtonLongPressAction {
  int get wireValue => switch (this) {
    PowerButtonLongPressAction.nothing => 0,
    PowerButtonLongPressAction.powerMenu => 1,
    PowerButtonLongPressAction.suspend => 2,
    PowerButtonLongPressAction.hibernate => 3,
    PowerButtonLongPressAction.powerOff => 4,
  };
}
