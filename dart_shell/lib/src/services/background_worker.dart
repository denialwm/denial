import 'dart:async';
import 'dart:isolate';

/// Entry point for one persistent background worker isolate.
///
/// The bootstrap list contains, in order, the port used to publish the
/// worker's command port and the port used for request responses.
typedef BackgroundWorkerEntrypoint = void Function(List<SendPort> bootstrap);

/// Handles one operation inside a background worker isolate.
typedef BackgroundWorkerOperationHandler =
    FutureOr<Object?> Function(int operation, Object? payload);

/// A reusable, persistent request/response channel to one worker isolate.
///
/// Feature-specific facades should expose strongly typed methods and keep the
/// integer operation protocol private. Results are decoded on the caller's
/// isolate after the potentially blocking operation has completed.
final class BackgroundWorker {
  BackgroundWorker({
    required BackgroundWorkerEntrypoint entrypoint,
    required String debugName,
  }) : this._(entrypoint, debugName);

  BackgroundWorker._(this._entrypoint, this._debugName);

  static const Duration _startupTimeout = Duration(seconds: 10);

  final BackgroundWorkerEntrypoint _entrypoint;
  final String _debugName;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};

  SendPort? _commands;
  Isolate? _isolate;
  ReceivePort? _responses;
  ReceivePort? _errors;
  ReceivePort? _exits;
  Future<SendPort>? _starting;
  int _generation = 0;
  int _nextRequestId = 1;

  Future<Result> invoke<Result>({
    required int operation,
    Object? payload,
    required Result Function(Object? response) decode,
  }) async {
    final commands = await _ensureStarted();
    final requestId = _nextRequestId++;
    final completer = Completer<Object?>();
    _pending[requestId] = completer;
    commands.send(<Object?>[requestId, operation, payload]);

    try {
      return decode(await completer.future);
    } finally {
      _pending.remove(requestId);
    }
  }

  Future<void> close() async {
    _failPending(StateError('Background worker $_debugName was closed'));
    _commands = null;
    _starting = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _closePorts();
  }

  Future<SendPort> _ensureStarted() {
    final commands = _commands;
    if (commands != null) {
      return Future<SendPort>.value(commands);
    }
    final starting = _starting;
    if (starting != null) {
      return starting;
    }
    final next = _start();
    _starting = next;
    return next.whenComplete(() {
      if (identical(_starting, next)) {
        _starting = null;
      }
    });
  }

  Future<SendPort> _start() async {
    final generation = ++_generation;
    final ready = ReceivePort();
    final responses = ReceivePort();
    final errors = ReceivePort();
    final exits = ReceivePort();

    _responses = responses;
    _errors = errors;
    _exits = exits;
    responses.listen((message) => _handleResponse(generation, message));
    errors.listen((message) => _handleFailure(generation, message));
    exits.listen((_) {
      _handleFailure(
        generation,
        StateError('Background worker $_debugName exited unexpectedly'),
      );
    });

    try {
      final isolate = await Isolate.spawn<List<SendPort>>(
        _entrypoint,
        <SendPort>[ready.sendPort, responses.sendPort],
        debugName: _debugName,
        errorsAreFatal: true,
        onError: errors.sendPort,
        onExit: exits.sendPort,
      );
      if (generation != _generation) {
        isolate.kill(priority: Isolate.immediate);
        throw StateError(
          'Background worker $_debugName startup was superseded',
        );
      }
      _isolate = isolate;
      final message = await ready.first.timeout(_startupTimeout);
      if (message is! SendPort) {
        throw StateError(
          'Background worker $_debugName returned an invalid command port',
        );
      }
      _commands = message;
      return message;
    } on Object {
      if (generation == _generation) {
        _commands = null;
        _isolate?.kill(priority: Isolate.immediate);
        _isolate = null;
        _closePorts();
      }
      rethrow;
    } finally {
      ready.close();
    }
  }

  void _handleResponse(int generation, Object? message) {
    if (generation != _generation ||
        message is! List<Object?> ||
        message.length < 3 ||
        message[0] is! int ||
        message[1] is! bool) {
      return;
    }
    final requestId = message[0]! as int;
    final completer = _pending[requestId];
    if (completer == null || completer.isCompleted) {
      return;
    }
    if (message[1]! as bool) {
      completer.complete(message[2]);
      return;
    }
    final description = message[2]?.toString() ?? 'unknown worker error';
    final remoteStack = message.length > 3 ? message[3]?.toString() : null;
    completer.completeError(
      BackgroundWorkerException(_debugName, description, remoteStack),
    );
  }

  void _handleFailure(int generation, Object? failure) {
    if (generation != _generation) {
      return;
    }
    _commands = null;
    _isolate = null;
    _failPending(
      failure is List<Object?> && failure.isNotEmpty
          ? StateError(failure.first.toString())
          : failure,
    );
    _closePorts();
  }

  void _failPending(Object? failure) {
    final error = failure is Object
        ? failure
        : StateError('Background worker $_debugName failed');
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    _pending.clear();
  }

  void _closePorts() {
    _responses?.close();
    _responses = null;
    _errors?.close();
    _errors = null;
    _exits?.close();
    _exits = null;
  }
}

/// Serves requests sent by [BackgroundWorker] in strict FIFO order.
///
/// Serial dispatch lets a worker safely retain native handles or other
/// isolate-owned state between calls. Errors are returned to the caller and
/// do not terminate the worker isolate.
void serveBackgroundWorker(
  List<SendPort> bootstrap,
  BackgroundWorkerOperationHandler handler,
) {
  if (bootstrap.length != 2) {
    throw ArgumentError.value(bootstrap, 'bootstrap');
  }
  final ready = bootstrap[0];
  final responses = bootstrap[1];
  final commands = ReceivePort();
  var tail = Future<void>.value();
  commands.listen((message) {
    tail = tail.then(
      (_) => _serveBackgroundRequest(message, responses, handler),
    );
  });
  ready.send(commands.sendPort);
}

Future<void> _serveBackgroundRequest(
  Object? message,
  SendPort responses,
  BackgroundWorkerOperationHandler handler,
) async {
  if (message is! List<Object?> ||
      message.length != 3 ||
      message[0] is! int ||
      message[1] is! int) {
    return;
  }
  final requestId = message[0]! as int;
  final operation = message[1]! as int;
  try {
    final result = await handler(operation, message[2]);
    responses.send(<Object?>[requestId, true, result]);
  } on Object catch (error, stackTrace) {
    responses.send(<Object?>[
      requestId,
      false,
      error.toString(),
      stackTrace.toString(),
    ]);
  }
}

final class BackgroundWorkerException implements Exception {
  const BackgroundWorkerException(
    this.worker,
    this.description,
    this.remoteStack,
  );

  final String worker;
  final String description;
  final String? remoteStack;

  @override
  String toString() => 'BackgroundWorkerException($worker): $description';
}
