import 'dart:convert';
import 'dart:io';

import 'package:denial_flutter_sdk/materials.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/wallpaper.dart';

import 'settings_controls.dart';

class SettingsWallpaperCard extends StatelessWidget {
  const SettingsWallpaperCard({
    required this.wallpaper,
    required this.wallpaperApps,
    required this.outputName,
    required this.onChoose,
    required this.chooseKey,
    super.key,
  });

  final WallpaperResource wallpaper;

  /// Null is unknown; an empty list confirms no app-managed background.
  final List<String>? wallpaperApps;
  final String? outputName;
  final VoidCallback onChoose;
  final Key chooseKey;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final apps = wallpaperApps;
    final external = apps != null && apps.isNotEmpty;
    final appNames =
        apps?.where((name) => name.trim().isNotEmpty).join(', ') ?? '';
    final theme = Theme.of(context).textTheme;
    final secondary = theme.bodyMedium?.copyWith(
      color: context.applicationColors.secondary,
      height: 1.5,
    );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          external ? l10n.settingsWallpaperLive : l10n.settingsWallpaperApplied,
          style: theme.labelLarge,
        ),
        if (external) ...[
          const SizedBox(height: 6),
          Text(
            appNames.isNotEmpty ? appNames : l10n.settingsWallpaperLive,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
        if (external || apps != null) ...[
          const SizedBox(height: 8),
          Text(
            external
                ? l10n.settingsWallpaperLiveDescription
                : l10n.settingsWallpaperDescription,
            style: secondary,
          ),
        ],
        if (outputName != null) ...[
          const SizedBox(height: 8),
          Text(l10n.settingsWallpaperDisplay(outputName!), style: secondary),
        ],
        const SizedBox(height: 16),
        _WallpaperActions(
          chooseKey: chooseKey,
          chooseLabel: external
              ? l10n.settingsWallpaperChooseFallback
              : l10n.settingsWallpaperChoose,
          onChoose: onChoose,
        ),
      ],
    );
    return SettingsCardGroup(
      key: const ValueKey('appearance-wallpaper-card'),
      title: l10n.settingsWallpaperTitle,
      children: [
        SettingsCardPadding(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final stacked =
                  constraints.maxWidth <
                  600 * (MediaQuery.textScalerOf(context).scale(14) / 14);
              final previewWidth = stacked
                  ? constraints.maxWidth.clamp(0.0, 360.0)
                  : 240.0;
              final preview = SizedBox(
                width: previewWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _WallpaperPreview(
                      wallpaper: wallpaper,
                      width: previewWidth,
                      label: external
                          ? l10n.settingsWallpaperFallback
                          : l10n.settingsWallpaperPreviewSemantics,
                    ),
                    if (external) ...[
                      const SizedBox(height: 8),
                      Text(
                        l10n.settingsWallpaperFallback,
                        style: theme.bodySmall?.copyWith(
                          color: context.applicationColors.secondary,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              );
              if (stacked) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [preview, const SizedBox(height: 20), details],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  preview,
                  const SizedBox(width: 24),
                  Expanded(child: details),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _WallpaperPreview extends StatelessWidget {
  const _WallpaperPreview({
    required this.wallpaper,
    required this.width,
    required this.label,
  });
  final WallpaperResource wallpaper;
  final double width;
  final String label;

  @override
  Widget build(BuildContext context) {
    final radius = DenialSurfaceGeometry.borderRadiusOf(context);
    return Semantics(
      image: true,
      label: label,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          foregroundDecoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: context.applicationColors.separator),
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Image(
              image: wallpaperImageProvider(
                wallpaper,
                targetPixelSize:
                    Size(width, width * 9 / 16) *
                    MediaQuery.devicePixelRatioOf(context),
              ),
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              errorBuilder: (_, _, _) => ColoredBox(
                color: context.applicationColors.control,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      context.l10n.settingsWallpaperPreviewUnavailable,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: context.applicationColors.secondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The picker button and the Bing daily shortcut. Bing is fetched on demand
/// and applied straight to the wallpaper store, so it never opens the picker.
class _WallpaperActions extends ConsumerStatefulWidget {
  const _WallpaperActions({
    required this.chooseKey,
    required this.chooseLabel,
    required this.onChoose,
  });

  final Key chooseKey;
  final String chooseLabel;
  final VoidCallback onChoose;

  @override
  ConsumerState<_WallpaperActions> createState() => _WallpaperActionsState();
}

class _WallpaperActionsState extends ConsumerState<_WallpaperActions> {
  static final Uri _archiveUri = Uri.parse(
    'https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=zh-CN',
  );
  static const Duration _requestTimeout = Duration(seconds: 20);
  static const Duration _downloadTimeout = Duration(seconds: 60);
  static const int _maximumBytes = 64 * 1024 * 1024;

  var _busy = false;
  String? _error;

  Future<void> _applyBingDaily() async {
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _error = null;
    });
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(_archiveUri).timeout(_requestTimeout);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'denial-settings/1.0',
      );
      final response = await request.close().timeout(_requestTimeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('Bing returned HTTP ${response.statusCode}');
      }
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_requestTimeout);
      final decoded = jsonDecode(body);
      final images = decoded is Map<String, dynamic> ? decoded['images'] : null;
      if (images is! List || images.isEmpty || images.first is! Map) {
        throw const FormatException('Invalid Bing response');
      }
      final image = (images.first as Map).cast<String, Object?>();
      final urlBase = image['urlbase'] as String?;
      final url = image['url'] as String?;
      final imageUri = urlBase != null && urlBase.isNotEmpty
          ? Uri.parse('https://www.bing.com${urlBase}_UHD.jpg')
          : url != null && url.isNotEmpty
          ? Uri.parse(
              url.startsWith('http') ? url : 'https://www.bing.com$url',
            )
          : null;
      if (imageUri == null) {
        throw const FormatException('Missing Bing image URL');
      }
      final title = (image['title'] as String?)?.trim();

      final imageRequest = await client
          .getUrl(imageUri)
          .timeout(_requestTimeout);
      imageRequest.headers.set(
        HttpHeaders.userAgentHeader,
        'denial-settings/1.0',
      );
      final imageResponse = await imageRequest.close().timeout(_downloadTimeout);
      if (imageResponse.statusCode != HttpStatus.ok) {
        await imageResponse.drain<void>();
        throw HttpException('Bing image returned HTTP ${imageResponse.statusCode}');
      }
      if (imageResponse.contentLength > _maximumBytes) {
        await imageResponse.drain<void>();
        throw const FormatException('Bing image is too large');
      }
      final paths = ref.read(runtimePathsProvider);
      final directory = Directory(paths.wallpaperDirectory);
      await directory.create(recursive: true);
      final now = DateTime.now();
      String two(int value) => value.toString().padLeft(2, '0');
      final stamp = '${now.year}${two(now.month)}${two(now.day)}';
      final file = File('${directory.path}/bing-daily-$stamp.jpg');
      final sink = file.openWrite();
      try {
        await imageResponse.pipe(sink).timeout(_downloadTimeout);
      } on Object {
        await sink.close();
        rethrow;
      }
      if (!mounted) {
        return;
      }
      ref
          .read(wallpaperControllerProvider.notifier)
          .commitCandidate(
            WallpaperCandidate(
              id: 'bing-daily-$stamp',
              providerId: 'bing',
              label: (title == null || title.isEmpty)
                  ? l10n.settingsWallpaperBingDaily
                  : title,
              previewUri: imageUri,
              downloadUri: imageUri,
              width: 3840,
              height: 2160,
              sourceUri: Uri.parse('https://www.bing.com'),
            ),
            WallpaperResource.file(file.path),
            revealOriginFraction: const Offset(0.5, 0.5),
            target: const WallpaperTarget.all(),
          );
      setState(() => _busy = false);
    } on Object catch (error) {
      debugPrint('Bing daily wallpaper failed: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _error = l10n.settingsWallpaperBingFailed;
      });
    } finally {
      client.close(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SettingsTextButton(
              key: widget.chooseKey,
              label: widget.chooseLabel,
              onPressed: widget.onChoose,
            ),
            SettingsTextButton(
              label: _busy
                  ? l10n.settingsWallpaperBingFetching
                  : l10n.settingsWallpaperBingDaily,
              onPressed: _busy ? null : _applyBingDaily,
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.35,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}
