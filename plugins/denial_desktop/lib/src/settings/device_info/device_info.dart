import 'dart:convert';
import 'dart:io';

/// Physical shape of the device, when the firmware describes one.
enum DeviceFormFactor { tablet, laptop, desktop, handheld }

/// A snapshot of the information the Device page shows. Every field is
/// best-effort: missing data is rendered as a dash rather than failing the
/// page, because some values depend on firmware or optional packages.
class DeviceInfo {
  const DeviceInfo({
    this.vendor,
    this.model,
    this.codename,
    this.sku,
    this.firmware,
    this.formFactor,
    this.osName,
    this.osBuild,
    this.kernel,
    this.architecture,
    this.hostname,
    this.timezone,
    this.timezoneOffset,
    this.uptime,
    this.socName,
    this.socVendor,
    this.gpu,
    this.cpuName,
    this.cpuCores,
    this.cpuMaxClock,
    this.memoryTotalBytes,
    this.memoryAvailableBytes,
    this.storageTotalBytes,
    this.storageFreeBytes,
    this.wifiInterface,
    this.ipAddress,
    this.macAddress,
    this.ethernetInterfaces = const <String>[],
    this.denialVersion,
    this.denialCommit,
    this.denialEngineVersion,
    this.pluginManagerVersion,
    this.denialDirty = false,
  });

  final String? vendor;
  final String? model;
  final String? codename;
  final String? sku;
  final String? firmware;
  final DeviceFormFactor? formFactor;

  final String? osName;
  final String? osBuild;
  final String? kernel;
  final String? architecture;
  final String? hostname;
  final String? timezone;
  final String? timezoneOffset;
  final Duration? uptime;

  final String? socName;
  final String? socVendor;
  final String? gpu;
  final String? cpuName;
  final int? cpuCores;
  final String? cpuMaxClock;
  final int? memoryTotalBytes;
  final int? memoryAvailableBytes;
  final int? storageTotalBytes;
  final int? storageFreeBytes;

  final String? wifiInterface;
  final String? ipAddress;
  final String? macAddress;
  final List<String> ethernetInterfaces;

  final String? denialVersion;
  final String? denialCommit;
  final String? denialEngineVersion;
  final String? pluginManagerVersion;
  final bool denialDirty;

  /// "Xiaomi Pad 5" when the firmware names both parts.
  String? get displayName {
    final vendor = this.vendor;
    final model = this.model;
    if (model == null || model.isEmpty) return vendor;
    if (vendor == null || vendor.isEmpty) return model;
    return model.toLowerCase().contains(vendor.toLowerCase())
        ? model
        : '$vendor $model';
  }
}

class DeviceInfoService {
  Future<DeviceInfo> load() async {
    final dmi = await _dmi();
    final compatible = await _compatible();
    final osRelease = await _osRelease();
    final memory = await _memory();
    final uptime = await _uptime();
    final network = await _network();
    final results = await Future.wait<Object?>([
      _cpu(),
      _storage(),
      _packages(),
    ]);
    final cpu = results[0] as _CpuInfo?;
    final storage = results[1] as _StorageInfo?;
    final packages = results[2] as Map<String, String>?;
    final soc = _resolveSoc(compatible);

    return DeviceInfo(
      vendor: dmi?['sys_vendor'],
      model: dmi?['product_name'],
      codename: dmi?['product_version'],
      sku: dmi?['product_sku'],
      firmware: dmi?['bios_version'],
      formFactor: _formFactor(dmi?['chassis_type'], dmi?['product_name']),
      osName: osRelease?['PRETTY_NAME'] ?? osRelease?['NAME'],
      osBuild: osRelease?['BUILD_ID'],
      kernel: await _readText('/proc/sys/kernel/osrelease'),
      architecture: cpu?.architecture,
      hostname: Platform.localHostname,
      timezone: _timezone(),
      timezoneOffset: _timezoneOffset(),
      uptime: uptime,
      socName: soc?.name,
      socVendor: soc?.vendor,
      gpu: soc?.gpu,
      cpuName: cpu?.modelName,
      cpuCores: cpu?.cores,
      cpuMaxClock: cpu?.maxClock,
      memoryTotalBytes: memory?.total,
      memoryAvailableBytes: memory?.available,
      storageTotalBytes: storage?.total,
      storageFreeBytes: storage?.available,
      wifiInterface: network.wifiInterface,
      ipAddress: network.ipAddress,
      macAddress: network.macAddress,
      ethernetInterfaces: network.ethernet,
      denialVersion: packages?['denial'],
      denialCommit: _commitOf(packages?['denial']),
      denialEngineVersion: _stripEpoch(
        packages?['denial-flutter-engine'],
      ),
      pluginManagerVersion: packages?['denial-plugin-manager'],
      denialDirty: packages?['denial']?.contains('.dirty') ?? false,
    );
  }

  Future<Map<String, String>?> _dmi() async {
    const base = '/sys/class/dmi/id';
    final fields = <String, String>{};
    for (final name in [
      'sys_vendor',
      'product_name',
      'product_version',
      'product_sku',
      'bios_version',
      'chassis_type',
    ]) {
      final value = await _readText('$base/$name');
      if (value != null && value.isNotEmpty) fields[name] = value;
    }
    return fields.isEmpty ? null : fields;
  }

  /// Device-tree identifiers such as `xiaomi,nabu` and `qcom,sm8150`.
  Future<List<String>> _compatible() async {
    try {
      final bytes = await File(
        '/sys/firmware/devicetree/base/compatible',
      ).readAsBytes();
      final entries = <String>[];
      final buffer = StringBuffer();
      for (final byte in bytes) {
        if (byte == 0) {
          entries.add(buffer.toString().trim());
          buffer.clear();
        } else {
          buffer.writeCharCode(byte);
        }
      }
      if (buffer.isNotEmpty) entries.add(buffer.toString().trim());
      return entries.where((entry) => entry.isNotEmpty).toList();
    } on FileSystemException {
      return const [];
    }
  }

  Future<Map<String, String>?> _osRelease() async {
    final text = await _readText('/etc/os-release');
    if (text == null) return null;
    final values = <String, String>{};
    for (final line in text.split('\n')) {
      final index = line.indexOf('=');
      if (index <= 0) continue;
      final key = line.substring(0, index).trim();
      var value = line.substring(index + 1).trim();
      if (value.length >= 2 &&
          value.startsWith('"') &&
          value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      values[key] = value;
    }
    return values;
  }

  Future<_CpuInfo?> _cpu() async {
    try {
      final result = await Process.run('lscpu', ['--json']);
      if (result.exitCode != 0) return null;
      final root =
          jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final rows = root['lscpu'] as List<dynamic>? ?? const [];
      final fields = <String, String>{
        for (final row in rows)
          (row['field'] as String).replaceAll(':', '').trim():
              (row['data'] as String?)?.trim() ?? '',
      };
      final cores = int.tryParse(fields['CPU(s)'] ?? '');
      return _CpuInfo(
        modelName: _cleanCpuName(fields['Model name']),
        cores: cores,
        architecture: _blankToNull(fields['Architecture']),
        maxClock: await _maxClock(fields['CPU max MHz']),
      );
    } on ProcessException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<String?> _maxClock(String? reportedMhz) async {
    // lscpu reports the first CPU only, which is usually a little core. Read
    // every policy so the value reflects the fastest cluster.
    var maxMhz = 0.0;
    for (var cpu = 0; cpu < 16; cpu++) {
      final value = await _readText(
        '/sys/devices/system/cpu/cpu$cpu/cpufreq/cpuinfo_max_freq',
      );
      final khz = double.tryParse(value ?? '');
      if (khz != null && khz > maxMhz) maxMhz = khz / 1000;
    }
    final reported = double.tryParse(reportedMhz ?? '');
    if (reported != null && reported > maxMhz) maxMhz = reported;
    if (maxMhz <= 0) return null;
    return '${(maxMhz / 1000).toStringAsFixed(2)} GHz';
  }

  Future<_MemoryInfo?> _memory() async {
    final text = await _readText('/proc/meminfo');
    if (text == null) return null;
    int? parse(String key) {
      final match = RegExp('^$key:\\s+(\\d+)', multiLine: true).firstMatch(text);
      final value = int.tryParse(match?.group(1) ?? '');
      return value == null ? null : value * 1024;
    }

    final total = parse('MemTotal');
    if (total == null) return null;
    return _MemoryInfo(total: total, available: parse('MemAvailable'));
  }

  Future<Duration?> _uptime() async {
    final text = await _readText('/proc/uptime');
    final seconds = double.tryParse(text?.split(' ').first ?? '');
    if (seconds == null) return null;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  Future<_StorageInfo?> _storage() async {
    try {
      final result = await Process.run('df', [
        '-B1',
        '--output=size,used,avail',
        '/',
      ]);
      if (result.exitCode != 0) return null;
      final lines = (result.stdout as String)
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
      if (lines.length < 2) return null;
      final fields = lines[1].split(RegExp(r'\s+'));
      if (fields.length < 3) return null;
      return _StorageInfo(
        total: int.tryParse(fields[0]),
        available: int.tryParse(fields[2]),
      );
    } on ProcessException {
      return null;
    }
  }

  Future<Map<String, String>?> _packages() async {
    try {
      final result = await Process.run('pacman', [
        '-Q',
        'denial',
        'denial-flutter-engine',
        'denial-plugin-manager',
      ]);
      final packages = <String, String>{};
      for (final line in (result.stdout as String).split('\n')) {
        final fields = line.trim().split(RegExp(r'\s+'));
        if (fields.length >= 2) packages[fields[0]] = fields[1];
      }
      return packages.isEmpty ? null : packages;
    } on ProcessException {
      return null;
    }
  }

  Future<_NetworkInfo> _network() async {
    try {
      final addresses = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      String? wifi;
      String? ip;
      final ethernet = <String>[];
      for (final interface in addresses) {
        final name = interface.name;
        if (name.startsWith('wlan') || name.startsWith('wlp')) {
          wifi ??= name;
          ip ??= interface.addresses.firstOrNull?.address;
        } else if (await _readText('/sys/class/net/$name/type') == '1') {
          ethernet.add(name);
        }
      }
      final mac = wifi == null
          ? null
          : await _readText('/sys/class/net/$wifi/address');
      return _NetworkInfo(
        wifiInterface: wifi,
        ipAddress: ip,
        macAddress: mac,
        ethernet: ethernet,
      );
    } on SocketException {
      return const _NetworkInfo(ethernet: []);
    } on FileSystemException {
      return const _NetworkInfo(ethernet: []);
    }
  }

  String? _timezone() {
    try {
      final target = Link('/etc/localtime').targetSync();
      final marker = target.indexOf('zoneinfo/');
      if (marker >= 0) return target.substring(marker + 'zoneinfo/'.length);
    } on FileSystemException {
      // Fall through to the plain file.
    }
    return null;
  }

  String? _timezoneOffset() {
    final offset = DateTime.now().timeZoneOffset;
    if (offset == Duration.zero) return '+00:00';
    final sign = offset.isNegative ? '-' : '+';
    final hours = offset.inHours.abs().toString().padLeft(2, '0');
    final minutes = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    return '$sign$hours:$minutes';
  }

  DeviceFormFactor? _formFactor(String? chassis, String? model) {
    switch (int.tryParse(chassis ?? '')) {
      case 30 || 31 || 32 || 11:
        return DeviceFormFactor.tablet;
      case 8 || 9 || 10 || 14:
        return DeviceFormFactor.laptop;
      case 3 || 4 || 5 || 6 || 7 || 15 || 16:
        return DeviceFormFactor.desktop;
    }
    if (model != null &&
        RegExp('pad|tab', caseSensitive: false).hasMatch(model)) {
      return DeviceFormFactor.tablet;
    }
    return null;
  }

  _Soc? _resolveSoc(List<String> compatible) {
    for (final entry in compatible) {
      if (!entry.startsWith('qcom,')) continue;
      final id = entry.substring('qcom,'.length).toLowerCase();
      for (final candidate in _socCatalog.entries) {
        if (id == candidate.key || id.startsWith('${candidate.key}-')) {
          return candidate.value;
        }
      }
      return _Soc(null, id.toUpperCase(), null);
    }
    return null;
  }

  String? _commitOf(String? version) {
    if (version == null) return null;
    final match = RegExp(r'\.g([0-9a-f]{7,})').firstMatch(version);
    return match?.group(1);
  }

  String? _stripEpoch(String? version) =>
      version?.replaceFirst(RegExp(r'^\d+:'), '');

  String? _blankToNull(String? value) =>
      value == null || value.isEmpty ? null : value;

  /// lscpu names the cluster it sampled; the page describes the whole SoC.
  String? _cleanCpuName(String? value) {
    final cleaned = _blankToNull(value)?.replaceFirst(
      RegExp(r'-(Gold|Silver)$', caseSensitive: false),
      '',
    );
    return cleaned;
  }

  Future<String?> _readText(String path) async {
    try {
      return (await File(path).readAsString()).trim();
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }
}

class _CpuInfo {
  const _CpuInfo({
    this.modelName,
    this.cores,
    this.architecture,
    this.maxClock,
  });

  final String? modelName;
  final int? cores;
  final String? architecture;
  final String? maxClock;
}

class _MemoryInfo {
  const _MemoryInfo({required this.total, this.available});

  final int total;
  final int? available;
}

class _StorageInfo {
  const _StorageInfo({this.total, this.available});

  final int? total;
  final int? available;
}

class _NetworkInfo {
  const _NetworkInfo({
    this.wifiInterface,
    this.ipAddress,
    this.macAddress,
    required this.ethernet,
  });

  final String? wifiInterface;
  final String? ipAddress;
  final String? macAddress;
  final List<String> ethernet;
}

class _Soc {
  const _Soc(this.vendor, this.name, this.gpu);

  final String? vendor;
  final String? name;
  final String? gpu;
}

/// Marketing names for the SoCs this compositor is likely to run on. Unknown
/// SoCs still show their device-tree identifier.
const _socCatalog = <String, _Soc>{
  'sm8150': _Soc('Qualcomm SM8150', 'Snapdragon 860', 'Adreno 640'),
  'sm8250': _Soc('Qualcomm SM8250', 'Snapdragon 865', 'Adreno 650'),
  'sm7325': _Soc('Qualcomm SM7325', 'Snapdragon 778G', 'Adreno 642L'),
  'sm7150': _Soc('Qualcomm SM7150', 'Snapdragon 730', 'Adreno 618'),
  'sm6115': _Soc('Qualcomm SM6115', 'Snapdragon 662', 'Adreno 610'),
  'sm6125': _Soc('Qualcomm SM6125', 'Snapdragon 665', 'Adreno 610'),
  'sdm845': _Soc('Qualcomm SDM845', 'Snapdragon 845', 'Adreno 630'),
  'msm8998': _Soc('Qualcomm MSM8998', 'Snapdragon 835', 'Adreno 540'),
};
