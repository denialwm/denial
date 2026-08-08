import 'desktop_app.dart';

enum HomeGridItemType { clock, batteryDischarge, app }

class HomeLayoutSlot {
  const HomeLayoutSlot({required this.id, this.colSpan, this.rowSpan});

  final String id;
  final int? colSpan;
  final int? rowSpan;
}

class HomeGridItem {
  const HomeGridItem._({
    required this.type,
    required this.id,
    required this.colSpan,
    required this.rowSpan,
    required this.app,
  });

  factory HomeGridItem.clock({
    int colSpan = defaultClockColSpan,
    int rowSpan = defaultClockRowSpan,
  }) {
    return HomeGridItem._(
      type: HomeGridItemType.clock,
      id: 'widget:clock',
      colSpan: colSpan.clamp(clockMinColSpan, clockMaxColSpan).toInt(),
      rowSpan: rowSpan.clamp(clockMinRowSpan, clockMaxRowSpan).toInt(),
      app: null,
    );
  }

  factory HomeGridItem.app(DesktopApp desktopApp) {
    return HomeGridItem._(
      type: HomeGridItemType.app,
      id: 'app:${desktopApp.id}',
      colSpan: 1,
      rowSpan: 1,
      app: desktopApp,
    );
  }

  factory HomeGridItem.batteryDischarge({
    int colSpan = defaultBatteryDischargeColSpan,
    int rowSpan = defaultBatteryDischargeRowSpan,
  }) {
    return HomeGridItem._(
      type: HomeGridItemType.batteryDischarge,
      id: 'widget:battery-discharge',
      colSpan: colSpan
          .clamp(batteryDischargeMinColSpan, batteryDischargeMaxColSpan)
          .toInt(),
      rowSpan: rowSpan
          .clamp(batteryDischargeMinRowSpan, batteryDischargeMaxRowSpan)
          .toInt(),
      app: null,
    );
  }

  static const int defaultClockColSpan = 2;
  static const int defaultClockRowSpan = 1;
  static const int clockMinColSpan = 2;
  static const int clockMaxColSpan = 4;
  static const int clockMinRowSpan = 1;
  static const int clockMaxRowSpan = 3;
  static const int defaultBatteryDischargeColSpan = 4;
  static const int defaultBatteryDischargeRowSpan = 2;
  static const int batteryDischargeMinColSpan = 2;
  static const int batteryDischargeMaxColSpan = 4;
  static const int batteryDischargeMinRowSpan = 1;
  static const int batteryDischargeMaxRowSpan = 3;

  final HomeGridItemType type;
  final String id;
  final int colSpan;
  final int rowSpan;
  final DesktopApp? app;

  bool get resizable => type != HomeGridItemType.app;

  int get minColSpan {
    return switch (type) {
      HomeGridItemType.clock => clockMinColSpan,
      HomeGridItemType.batteryDischarge => batteryDischargeMinColSpan,
      HomeGridItemType.app => 1,
    };
  }

  int get maxColSpan {
    return switch (type) {
      HomeGridItemType.clock => clockMaxColSpan,
      HomeGridItemType.batteryDischarge => batteryDischargeMaxColSpan,
      HomeGridItemType.app => 1,
    };
  }

  int get minRowSpan {
    return switch (type) {
      HomeGridItemType.clock => clockMinRowSpan,
      HomeGridItemType.batteryDischarge => batteryDischargeMinRowSpan,
      HomeGridItemType.app => 1,
    };
  }

  int get maxRowSpan {
    return switch (type) {
      HomeGridItemType.clock => clockMaxRowSpan,
      HomeGridItemType.batteryDischarge => batteryDischargeMaxRowSpan,
      HomeGridItemType.app => 1,
    };
  }

  HomeGridItem resize({required int colSpan, required int rowSpan}) {
    if (!resizable) {
      return this;
    }
    return switch (type) {
      HomeGridItemType.clock => HomeGridItem.clock(
        colSpan: colSpan,
        rowSpan: rowSpan,
      ),
      HomeGridItemType.batteryDischarge => HomeGridItem.batteryDischarge(
        colSpan: colSpan,
        rowSpan: rowSpan,
      ),
      HomeGridItemType.app => this,
    };
  }
}
