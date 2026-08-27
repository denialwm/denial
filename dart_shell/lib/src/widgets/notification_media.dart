import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../launcher/controllers/home_grid_controller.dart';
import '../models/desktop_notification.dart';
import '../theme/shell_theme.dart';
import 'app_icon.dart';

@immutable
class NotificationIconRequest {
  const NotificationIconRequest({
    required this.appIcon,
    required this.desktopEntry,
  });

  final String appIcon;
  final String desktopEntry;

  @override
  bool operator ==(Object other) {
    return other is NotificationIconRequest &&
        other.appIcon == appIcon &&
        other.desktopEntry == desktopEntry;
  }

  @override
  int get hashCode => Object.hash(appIcon, desktopEntry);
}

final notificationIconPathProvider =
    FutureProvider.family<String?, NotificationIconRequest>((ref, request) {
      final repository = ref.watch(desktopAppsRepositoryProvider);
      return Isolate.run(
        () => repository.resolveNotificationIcon(
          appIcon: request.appIcon,
          desktopEntry: request.desktopEntry,
        ),
      );
    }, isAutoDispose: true);

const int maxNotificationStaticImageBytes = 4 * 1024 * 1024;

final notificationStaticImageProvider =
    FutureProvider.family<Uint8List?, String>(
      (ref, path) => Isolate.run(() => loadBoundedNotificationImage(path)),
      isAutoDispose: true,
    );

@visibleForTesting
Uint8List? loadBoundedNotificationImage(String path) {
  RandomAccessFile? handle;
  try {
    final file = File(path);
    final stat = file.statSync();
    if (stat.type != FileSystemEntityType.file ||
        stat.size <= 0 ||
        stat.size > maxNotificationStaticImageBytes) {
      return null;
    }
    handle = file.openSync();
    final bytes = handle.readSync(maxNotificationStaticImageBytes + 1);
    return bytes.isEmpty || bytes.length > maxNotificationStaticImageBytes
        ? null
        : bytes;
  } on FileSystemException {
    return null;
  } finally {
    try {
      handle?.closeSync();
    } on FileSystemException {
      // The bounded read has already completed or failed; close errors do not
      // make the notification surface actionable.
    }
  }
}

class NotificationAppIcon extends ConsumerWidget {
  const NotificationAppIcon({required this.notification, super.key});

  final DesktopNotification notification;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (notification.appIcon.isEmpty && notification.desktopEntry.isEmpty) {
      return const AppIconImage(iconPath: null);
    }
    final resolved = ref.watch(
      notificationIconPathProvider(
        NotificationIconRequest(
          appIcon: notification.appIcon,
          desktopEntry: notification.desktopEntry,
        ),
      ),
    );
    return AppIconImage(iconPath: resolved.value);
  }
}

/// Renders the freedesktop raw-image tuple or static image path, falling back
/// to the resolved application icon. All decoded textures are capped even
/// though the wire payload is already byte-bounded.
class NotificationArtwork extends ConsumerWidget {
  const NotificationArtwork({
    required this.notification,
    required this.size,
    super.key,
    this.preferContentImage = true,
  });

  final DesktopNotification notification;
  final double size;
  final bool preferContentImage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final image = notification.imageData;
    final imagePath = _localImagePath(notification.imagePath);
    Widget content;
    if (preferContentImage && image != null) {
      content = _RawNotificationImage(image: image);
    } else if (preferContentImage && imagePath != null) {
      final cacheSize = (size * MediaQuery.devicePixelRatioOf(context))
          .ceil()
          .clamp(32, 512);
      final bytes = ref.watch(notificationStaticImageProvider(imagePath));
      final data = bytes.value;
      content = data == null
          ? NotificationAppIcon(notification: notification)
          : Image.memory(
              data,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              cacheWidth: cacheSize,
              cacheHeight: cacheSize,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) =>
                  NotificationAppIcon(notification: notification),
            );
    } else {
      content = NotificationAppIcon(notification: notification);
    }

    return RepaintBoundary(
      child: SizedBox.square(
        dimension: size,
        child: ClipRRect(
          borderRadius: context.shellTheme.borderRadius(size * 0.24),
          child: content,
        ),
      ),
    );
  }
}

String? _localImagePath(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.scheme == 'file') {
    try {
      return uri.toFilePath();
    } on UnsupportedError {
      return null;
    }
  }
  if (uri != null && uri.hasScheme) {
    return null;
  }
  return trimmed.startsWith('/') ? trimmed : null;
}

class _RawNotificationImage extends StatefulWidget {
  const _RawNotificationImage({required this.image});

  final DesktopNotificationImageData image;

  @override
  State<_RawNotificationImage> createState() => _RawNotificationImageState();
}

class _RawNotificationImageState extends State<_RawNotificationImage> {
  ui.Image? _decoded;
  int _decodeGeneration = 0;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(covariant _RawNotificationImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.image, widget.image)) {
      _decode();
    }
  }

  Future<void> _decode() async {
    final generation = ++_decodeGeneration;
    final pixels = _rgbaPixels(widget.image);
    if (pixels == null) {
      _replaceDecoded(null, generation);
      return;
    }

    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? decoded;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: widget.image.width,
        height: widget.image.height,
        rowBytes: widget.image.width * 4,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      final longest = widget.image.width > widget.image.height
          ? widget.image.width
          : widget.image.height;
      final scale = longest > 512 ? 512 / longest : 1.0;
      codec = await descriptor.instantiateCodec(
        targetWidth: (widget.image.width * scale).round().clamp(1, 512),
        targetHeight: (widget.image.height * scale).round().clamp(1, 512),
      );
      decoded = (await codec.getNextFrame()).image;
    } on Object catch (error) {
      debugPrint(
        'Unable to decode bounded notification image: ${error.runtimeType}',
      );
      decoded?.dispose();
      decoded = null;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
    _replaceDecoded(decoded, generation);
  }

  void _replaceDecoded(ui.Image? image, int generation) {
    if (!mounted || generation != _decodeGeneration) {
      image?.dispose();
      return;
    }
    final previous = _decoded;
    setState(() => _decoded = image);
    previous?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final decoded = _decoded;
    if (decoded == null) {
      return const SizedBox.expand();
    }
    return RawImage(
      image: decoded,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
    );
  }

  @override
  void dispose() {
    _decodeGeneration += 1;
    _decoded?.dispose();
    super.dispose();
  }
}

Uint8List? _rgbaPixels(DesktopNotificationImageData image) {
  if (image.width <= 0 ||
      image.height <= 0 ||
      image.width > 4096 ||
      image.height > 4096 ||
      image.bitsPerSample != 8 ||
      (image.channels != 3 && image.channels != 4) ||
      image.rowStride < image.width * image.channels) {
    return null;
  }
  final requiredBytes = image.rowStride * image.height;
  if (requiredBytes != image.data.length || requiredBytes > 512 * 1024) {
    return null;
  }

  final output = Uint8List(image.width * image.height * 4);
  for (var y = 0; y < image.height; y += 1) {
    final sourceRow = y * image.rowStride;
    final outputRow = y * image.width * 4;
    for (var x = 0; x < image.width; x += 1) {
      final source = sourceRow + x * image.channels;
      final target = outputRow + x * 4;
      output[target] = image.data[source];
      output[target + 1] = image.data[source + 1];
      output[target + 2] = image.data[source + 2];
      output[target + 3] = image.channels == 4 ? image.data[source + 3] : 0xff;
    }
  }
  return output;
}
