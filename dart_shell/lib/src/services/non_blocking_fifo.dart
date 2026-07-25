import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

typedef _OpenNative = Int32 Function(Pointer<Uint8>, Int32);
typedef _OpenDart = int Function(Pointer<Uint8>, int);
typedef _WriteNative = IntPtr Function(Int32, Pointer<Void>, IntPtr);
typedef _WriteDart = int Function(int, Pointer<Void>, int);
typedef _CloseNative = Int32 Function(Int32);
typedef _CloseDart = int Function(int);
typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _MallocDart = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);
typedef _ErrnoLocationNative = Pointer<Int32> Function();
typedef _ErrnoLocationDart = Pointer<Int32> Function();

/// Writes short commands to an existing Linux FIFO without spawning a process.
///
/// Dart's regular file API does not expose `O_NONBLOCK`; using it here keeps a
/// missing daemon from ever blocking the embedded shell isolate.
class NonBlockingFifoWriter {
  NonBlockingFifoWriter() : _libc = DynamicLibrary.open('libc.so.6') {
    _open = _libc.lookupFunction<_OpenNative, _OpenDart>('open');
    _write = _libc.lookupFunction<_WriteNative, _WriteDart>('write');
    _close = _libc.lookupFunction<_CloseNative, _CloseDart>('close');
    _malloc = _libc.lookupFunction<_MallocNative, _MallocDart>('malloc');
    _free = _libc.lookupFunction<_FreeNative, _FreeDart>('free');
    _errnoLocation =
        _libc.lookupFunction<_ErrnoLocationNative, _ErrnoLocationDart>(
      '__errno_location',
    );
  }

  static const int _oWriteOnly = 0x1;
  static const int _oNonBlock = 0x800;
  static const int _oCloseOnExec = 0x80000;
  static const int _interrupted = 4;

  final DynamicLibrary _libc;
  late final _OpenDart _open;
  late final _WriteDart _write;
  late final _CloseDart _close;
  late final _MallocDart _malloc;
  late final _FreeDart _free;
  late final _ErrnoLocationDart _errnoLocation;

  void writeLine(String path, String command) {
    if (command.isEmpty || command.contains('\n') || command.contains('\r')) {
      throw ArgumentError.value(command, 'command', 'Comando FIFO non valido');
    }
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.pipe) {
      throw FileSystemException('Canale PBO non disponibile', path);
    }

    final pathBytes = utf8.encode('$path\u0000');
    final commandBytes = utf8.encode('$command\n');
    final nativePath = _copyToNative(pathBytes);
    Pointer<Uint8>? nativeCommand;
    var descriptor = -1;
    try {
      descriptor = _open(
        nativePath,
        _oWriteOnly | _oNonBlock | _oCloseOnExec,
      );
      if (descriptor < 0) {
        final errno = _errno;
        throw FileSystemException(
          'Daemon PBO non disponibile',
          path,
          OSError('open', errno),
        );
      }

      nativeCommand = _copyToNative(commandBytes);
      var offset = 0;
      while (offset < commandBytes.length) {
        final written = _write(
          descriptor,
          (nativeCommand + offset).cast<Void>(),
          commandBytes.length - offset,
        );
        if (written < 0) {
          final errno = _errno;
          if (errno == _interrupted) {
            continue;
          }
          throw FileSystemException(
            'Invio del comando PBO non riuscito',
            path,
            OSError('write', errno),
          );
        }
        if (written == 0) {
          throw FileSystemException(
            'Il daemon PBO non accetta comandi',
            path,
          );
        }
        offset += written;
      }
    } finally {
      if (descriptor >= 0) {
        _close(descriptor);
      }
      if (nativeCommand != null) {
        _free(nativeCommand.cast<Void>());
      }
      _free(nativePath.cast<Void>());
    }
  }

  int get _errno => _errnoLocation().value;

  Pointer<Uint8> _copyToNative(List<int> bytes) {
    final pointer = _malloc(bytes.length).cast<Uint8>();
    if (pointer.address == 0) {
      throw StateError('Memoria insufficiente per il comando FIFO');
    }
    pointer.asTypedList(bytes.length).setAll(0, bytes);
    return pointer;
  }
}
