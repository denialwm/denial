/// SIM presence is separate from modem discovery and WWAN policy.
enum MobileSimPresence { unknown, absent, present }

/// Interpret only ModemManager evidence; no SIM object reads/identifiers needed.
/// Sim identifies the *active* SIM, while SimSlots includes inactive cards.
/// During initialization an empty path is not a removal report. A SIM lock or
/// SIM_ERROR proves presence even if the SIM object cannot yet be exported.
MobileSimPresence mobileSimPresence({
  String? simPath,
  List<String>? simSlots,
  required int unlockRequired,
  required int state,
  required int failedReason,
  MobileSimPresence previous = MobileSimPresence.unknown,
}) {
  bool hasPath(String? path) => path != null && path.isNotEmpty && path != '/';
  if (hasPath(simPath) ||
      (simSlots?.any(hasPath) ?? false) ||
      (unlockRequired >= 2 && unlockRequired <= 5) ||
      (state == -1 && failedReason == 3)) {
    return MobileSimPresence.present;
  }
  // MM_MODEM_STATE_FAILED_REASON_SIM_MISSING = 2. Other failures (including
  // SIM_ERROR and eSIM-without-profiles) are not physical SIM absence.
  if ((state == -1 && failedReason == 2) ||
      (state >= 3 &&
          simSlots != null &&
          simSlots.isNotEmpty &&
          simSlots.every((path) => path == '/'))) {
    return MobileSimPresence.absent;
  }
  // Sim='/' alone describes no *active* SIM, not necessarily no inserted SIM.
  return previous == MobileSimPresence.present
      ? previous
      : MobileSimPresence.unknown;
}

class MobileNetworkSnapshot {
  const MobileNetworkSnapshot({
    this.modemPath,
    this.simPath,
    this.simPresence = MobileSimPresence.unknown,
    this.unlockRequired = 0,
    this.pinRetries,
    this.strength = 0,
    this.registered = false,
    this.connected = false,
    this.enabled = false,
    this.hardwareEnabled = false,
    this.managerAvailable = false,
    this.operatorName = '',
    this.technology = '',
  });

  final String? modemPath;
  final String? simPath;
  final MobileSimPresence simPresence;
  final int unlockRequired;
  final int? pinRetries;
  final int strength;
  final bool registered;
  final bool connected;
  final bool enabled;
  final bool hardwareEnabled;
  final bool managerAvailable;
  final String operatorName;

  /// The network generation: '2G' to '5G', empty when not registered.
  final String technology;
  bool get showCellular => simPresence != MobileSimPresence.absent;
  bool get cellularWorking =>
      simPresence == MobileSimPresence.present &&
      !locked &&
      registered &&
      connected &&
      managerAvailable &&
      enabled &&
      hardwareEnabled;

  /// Backend loss invalidates connectivity, never proves SIM removal. Do not
  /// retain actionable SIM paths or PIN state after discovery fails.
  MobileNetworkSnapshot unavailable() => MobileNetworkSnapshot(
    modemPath: modemPath,
    simPresence: simPresence == MobileSimPresence.present
        ? MobileSimPresence.present
        : MobileSimPresence.unknown,
  );

  bool get pinRequired => unlockRequired == 2 && simPath != null;
  // PIN2/PUK2 protect supplementary SIM functions, not normal modem use.
  // ModemManager permits initialization and registration with these locks.
  bool get locked =>
      unlockRequired > 1 && unlockRequired != 3 && unlockRequired != 5;
  bool get canToggle =>
      managerAvailable && hardwareEnabled && modemPath != null;

  @override
  bool operator ==(Object other) =>
      other is MobileNetworkSnapshot &&
      other.modemPath == modemPath &&
      other.simPath == simPath &&
      other.simPresence == simPresence &&
      other.unlockRequired == unlockRequired &&
      other.pinRetries == pinRetries &&
      other.strength == strength &&
      other.registered == registered &&
      other.connected == connected &&
      other.enabled == enabled &&
      other.hardwareEnabled == hardwareEnabled &&
      other.managerAvailable == managerAvailable &&
      other.operatorName == operatorName &&
      other.technology == technology;

  @override
  int get hashCode => Object.hash(
    modemPath,
    simPath,
    simPresence,
    unlockRequired,
    pinRetries,
    strength,
    registered,
    connected,
    enabled,
    hardwareEnabled,
    managerAvailable,
    operatorName,
    technology,
  );
}

/// Pick one truthful status across modems: never hide a present/unknown SIM
/// because another modem has empty slots. Keep the existing locked-SIM priority.
MobileNetworkSnapshot selectMobileNetworkSnapshot(
  Iterable<MobileNetworkSnapshot> modems, {
  required MobileNetworkSnapshot previous,
}) {
  int rank(MobileNetworkSnapshot snapshot) {
    final presence = switch (snapshot.simPresence) {
      MobileSimPresence.present => 2,
      MobileSimPresence.unknown => 1,
      MobileSimPresence.absent => 0,
    };
    final status = snapshot.locked
        ? 3
        : snapshot.connected
        ? 2
        : snapshot.registered
        ? 1
        : 0;
    return presence * 4 + status;
  }

  final candidates = modems.toList();
  // Object removal can be a reprobe/slot switch. Absence on another modem
  // cannot confirm removal of the previously observed SIM.
  if (previous.simPresence == MobileSimPresence.present &&
      previous.modemPath != null &&
      !candidates.any((modem) => modem.modemPath == previous.modemPath)) {
    candidates.add(previous.unavailable());
  }
  final sorted = candidates
    ..sort((a, b) {
      final order = rank(b).compareTo(rank(a));
      return order != 0
          ? order
          : (a.modemPath ?? '').compareTo(b.modemPath ?? '');
    });
  // An empty export can be a service restart/reprobe, not SIM removal.
  return sorted.firstOrNull ?? previous.unavailable();
}

/// ModemManager's AccessTechnologies flags as a network generation.
String mobileTechnologyFromModemManager(int flags) {
  bool any(List<int> bits) => bits.any((bit) => flags & (1 << bit) != 0);
  // MM_MODEM_ACCESS_TECHNOLOGY bit numbers.
  if (any([15])) return '5G';
  if (any([14, 16, 17])) return '4G'; // LTE, LTE Cat-M, NB-IoT
  if (any([5, 6, 7, 8, 9, 11, 12, 13])) return '3G'; // UMTS to HSPA+, EV-DO
  if (any([1, 2, 3, 4, 10])) return '2G'; // GSM to EDGE, 1xRTT
  return '';
}

/// dmail's single modem and SIM both live at this path.
const dmailPath = '/org/dmail';

/// A snapshot from dmail's Modem1 and Data1 properties. dmail owns the SIM,
/// registration and the data session, so it answers for NetworkManager's WWAN
/// switches too.
MobileNetworkSnapshot dmailNetworkSnapshot({
  required String state,
  required String technology,
  required int signal,
  required String operatorName,
  required int pinRetries,
  required bool dataEnabled,
  required String dataState,
  MobileSimPresence previous = MobileSimPresence.unknown,
}) {
  final simPresence = switch (state) {
    'locked' || 'searching' || 'registered' => MobileSimPresence.present,
    'no-sim' => MobileSimPresence.absent,
    // Starting or failed: no evidence either way.
    _ =>
      previous == MobileSimPresence.present
          ? previous
          : MobileSimPresence.unknown,
  };
  final locked = state == 'locked';
  return MobileNetworkSnapshot(
    modemPath: state == 'failed' ? null : dmailPath,
    simPath: simPresence == MobileSimPresence.present ? dmailPath : null,
    simPresence: simPresence,
    // ModemManager's lock codes, which the rest of the shell reads: 1 none,
    // 2 SIM PIN, 4 SIM PUK. dmail reports a blocked PIN as no retries left.
    unlockRequired: !locked
        ? 1
        : pinRetries == 0
        ? 4
        : 2,
    pinRetries: locked ? pinRetries : null,
    strength: signal.clamp(0, 100),
    registered: state == 'registered',
    connected: dataState == 'connected',
    enabled: dataEnabled,
    hardwareEnabled: true,
    managerAvailable: true,
    operatorName: operatorName,
    technology: technology == 'none' ? '' : technology.toUpperCase(),
  );
}
