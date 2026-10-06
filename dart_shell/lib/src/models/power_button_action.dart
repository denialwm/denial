enum PowerButtonAction { suspend, hibernate, dpms, powerOff }

extension PowerButtonActionWireValue on PowerButtonAction {
  int get wireValue => switch (this) {
    PowerButtonAction.dpms => 0,
    PowerButtonAction.suspend => 1,
    PowerButtonAction.hibernate => 2,
    PowerButtonAction.powerOff => 3,
  };
}
