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
