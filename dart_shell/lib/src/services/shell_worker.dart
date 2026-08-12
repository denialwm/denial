import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:ffi/ffi.dart' as pkg_ffi;

import 'background_worker.dart';

/// Process-wide facade for work which must never execute on Flutter's UI
/// isolate.
///
/// Public methods remain strongly typed. Each method chooses an appropriate
/// persistent worker lane so future blocking domains do not need to share one
/// isolate merely because they share this facade.
final class ShellWorker {
  ShellWorker._();

  static final ShellWorker instance = ShellWorker._();

  final BackgroundWorker _nvidia = BackgroundWorker(
    entrypoint: _nvidiaWorkerMain,
    debugName: 'denial-nvidia-worker',
  );

  Future<List<NvidiaGpuSample>> readNvidiaGpuSamples() {
    return _nvidia.invoke<List<NvidiaGpuSample>>(
      operation: _readNvidiaGpuSamples,
      decode: _decodeNvidiaGpuSamples,
    );
  }
}

final class NvidiaGpuSample {
  const NvidiaGpuSample({
    required this.index,
    required this.usage,
    required this.temperatureC,
  });

  final int index;
  final double usage;
  final double? temperatureC;
}

const int _readNvidiaGpuSamples = 1;

List<NvidiaGpuSample> _decodeNvidiaGpuSamples(Object? response) {
  if (response is! List<Object?>) {
    throw const FormatException('Invalid NVIDIA worker response');
  }
  return <NvidiaGpuSample>[
    for (final row in response)
      if (row is List<Object?> &&
          row.length == 3 &&
          row[0] is int &&
          row[1] is double &&
          (row[2] == null || row[2] is double))
        NvidiaGpuSample(
          index: row[0]! as int,
          usage: row[1]! as double,
          temperatureC: row[2] as double?,
        )
      else
        throw const FormatException('Invalid NVIDIA GPU sample'),
  ];
}

@pragma('vm:entry-point')
void _nvidiaWorkerMain(List<SendPort> bootstrap) {
  final reader = _NativeNvmlReader();
  serveBackgroundWorker(bootstrap, (operation, _) {
    if (operation != _readNvidiaGpuSamples) {
      throw UnsupportedError('Unknown NVIDIA worker operation $operation');
    }
    return reader.read();
  });
}

/// NVML is deliberately confined to the NVIDIA worker isolate. No native
/// handles or FFI-backed objects cross the isolate boundary.
final class _NativeNvmlReader {
  bool _unavailable = false;
  ffi.DynamicLibrary? _library;
  List<ffi.Pointer<ffi.Void>> _devices = const <ffi.Pointer<ffi.Void>>[];
  late final int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<_NvmlUtilization>)
  _getUtilization;
  int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Uint32>)?
  _getTemperature;

  List<Object?> read() {
    if (_unavailable || (_library == null && !_initialize())) {
      return const <Object?>[];
    }
    final utilization = pkg_ffi.calloc<_NvmlUtilization>();
    final temperature = pkg_ffi.calloc<ffi.Uint32>();
    try {
      final samples = <Object?>[];
      for (var index = 0; index < _devices.length; index += 1) {
        final device = _devices[index];
        if (_getUtilization(device, utilization) != 0) {
          continue;
        }
        double? temperatureC;
        final getTemperature = _getTemperature;
        if (getTemperature != null &&
            getTemperature(device, 0, temperature) == 0) {
          temperatureC = temperature.value.toDouble();
        }
        samples.add(<Object?>[
          index,
          (utilization.ref.gpu / 100.0).clamp(0.0, 1.0),
          temperatureC,
        ]);
      }
      return samples;
    } finally {
      pkg_ffi.calloc.free(utilization);
      pkg_ffi.calloc.free(temperature);
    }
  }

  bool _initialize() {
    try {
      final library = ffi.DynamicLibrary.open('libnvidia-ml.so.1');
      final init = library.lookupFunction<ffi.Int32 Function(), int Function()>(
        'nvmlInit_v2',
      );
      if (init() != 0) {
        _unavailable = true;
        return false;
      }
      final getCount = library
          .lookupFunction<
            ffi.Int32 Function(ffi.Pointer<ffi.Uint32>),
            int Function(ffi.Pointer<ffi.Uint32>)
          >('nvmlDeviceGetCount_v2');
      final getHandle = library
          .lookupFunction<
            ffi.Int32 Function(ffi.Uint32, ffi.Pointer<ffi.Pointer<ffi.Void>>),
            int Function(int, ffi.Pointer<ffi.Pointer<ffi.Void>>)
          >('nvmlDeviceGetHandleByIndex_v2');
      _getUtilization = library
          .lookupFunction<
            ffi.Int32 Function(
              ffi.Pointer<ffi.Void>,
              ffi.Pointer<_NvmlUtilization>,
            ),
            int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<_NvmlUtilization>)
          >('nvmlDeviceGetUtilizationRates');
      try {
        _getTemperature = library
            .lookupFunction<
              ffi.Int32 Function(
                ffi.Pointer<ffi.Void>,
                ffi.Int32,
                ffi.Pointer<ffi.Uint32>,
              ),
              int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Uint32>)
            >('nvmlDeviceGetTemperature');
      } on Object {
        _getTemperature = null;
      }

      final count = pkg_ffi.calloc<ffi.Uint32>();
      final handle = pkg_ffi.calloc<ffi.Pointer<ffi.Void>>();
      try {
        if (getCount(count) != 0) {
          _unavailable = true;
          return false;
        }
        _devices = <ffi.Pointer<ffi.Void>>[
          for (var index = 0; index < count.value; index += 1)
            if (getHandle(index, handle) == 0) handle.value,
        ];
      } finally {
        pkg_ffi.calloc.free(count);
        pkg_ffi.calloc.free(handle);
      }
      _library = library;
      return true;
    } on Object {
      _unavailable = true;
      return false;
    }
  }
}

final class _NvmlUtilization extends ffi.Struct {
  @ffi.Uint32()
  external int gpu;

  @ffi.Uint32()
  external int memory;
}
