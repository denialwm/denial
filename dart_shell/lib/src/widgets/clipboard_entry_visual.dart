part of 'clipboard_tray_layer.dart';

class _ClipboardEntryVisual extends StatelessWidget {
  const _ClipboardEntryVisual({
    required this.entry,
    this.highlighted = false,
    this.lifted = false,
  });

  final ClipboardHistoryEntry entry;
  final bool highlighted;
  final bool lifted;

  @override
  Widget build(BuildContext context) {
    final imageMime = clipboardImageMimeType(entry);
    if (imageMime != null) {
      return _ClipboardImageTile(entry: entry, mimeType: imageMime);
    }
    final fileMime = clipboardFileMimeType(entry);
    if (fileMime != null) {
      return _ClipboardFileTile(
        entry: entry,
        mimeType: fileMime,
        highlighted: highlighted,
        lifted: lifted,
      );
    }
    return _ClipboardTextTile(
      entry: entry,
      highlighted: highlighted,
      lifted: lifted,
    );
  }
}

class _ClipboardImageTile extends StatelessWidget {
  const _ClipboardImageTile({required this.entry, required this.mimeType});

  final ClipboardHistoryEntry entry;
  final String mimeType;

  @override
  Widget build(BuildContext context) {
    final requestedSize = _clipboardImageDisplaySize(entry);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = _fitClipboardImageSize(requestedSize, constraints);
        return SizedBox(
          width: size.width,
          height: size.height,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: _ClipboardImagePreview(
              entry: entry,
              mimeType: mimeType,
              displaySize: size,
            ),
          ),
        );
      },
    );
  }
}

class _ClipboardImagePreview extends ConsumerWidget {
  const _ClipboardImagePreview({
    required this.entry,
    required this.mimeType,
    required this.displaySize,
  });

  final ClipboardHistoryEntry entry;
  final String mimeType;
  final Size displaySize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = math.max(1, (displaySize.width * pixelRatio).ceil());
    final cacheHeight = math.max(1, (displaySize.height * pixelRatio).ceil());
    final data = ref.watch(
      clipboardEntryDataProvider(ClipboardDataKey(entry.id, mimeType)),
    );
    return RepaintBoundary(
      child: ColoredBox(
        color: context.shellColors.surfaceContainerLow,
        child: data.when(
          data: (payload) => Image.memory(
            payload.bytes,
            fit: BoxFit.contain,
            cacheWidth: cacheWidth,
            cacheHeight: cacheHeight,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
            semanticLabel: context.l10n.clipboardImagePreview,
            errorBuilder: (_, _, _) => _PreviewFallback(
              icon: Icons.broken_image_outlined,
              label: context.l10n.clipboardPreviewUnavailable,
            ),
          ),
          loading: () =>
              const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          error: (_, _) => _PreviewFallback(
            icon: Icons.broken_image_outlined,
            label: context.l10n.clipboardPreviewUnavailable,
          ),
        ),
      ),
    );
  }
}

class _ClipboardFileTile extends ConsumerWidget {
  const _ClipboardFileTile({
    required this.entry,
    required this.mimeType,
    required this.highlighted,
    required this.lifted,
  });

  final ClipboardHistoryEntry entry;
  final String mimeType;
  final bool highlighted;
  final bool lifted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ShellTheme.of(context).accentPalette;
    final data = ref.watch(
      clipboardEntryDataProvider(ClipboardDataKey(entry.id, mimeType)),
    );
    final files = data.maybeWhen(
      data: (payload) =>
          clipboardFileUris(utf8.decode(payload.bytes, allowMalformed: true)),
      orElse: () => clipboardFileUris(entry.preview),
    );
    final first = files.isEmpty ? null : files.first;
    final thumbnail = first != null && clipboardUriCanRenderAsImage(first)
        ? ref.watch(clipboardLocalFilePreviewProvider(first))
        : null;
    final isFolder = first?.path.endsWith('/') ?? false;
    final name = first == null
        ? context.l10n.clipboardFileSelection
        : first.pathSegments
                  .where((segment) => segment.isNotEmpty)
                  .lastOrNull ??
              first.path;

    return AnimatedContainer(
      duration: Motion.cardSettle,
      curve: Motion.standard,
      width: 280,
      height: 64,
      padding: const EdgeInsets.all(9),
      decoration: _clipboardNoteDecoration(
        context,
        entry: entry,
        highlighted: highlighted,
        lifted: lifted,
      ),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 46,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: ColoredBox(
                color: accent.subtle,
                child: thumbnail == null
                    ? Icon(
                        isFolder
                            ? Icons.folder_rounded
                            : Icons.insert_drive_file_rounded,
                        size: 24,
                        color: accent.primary,
                      )
                    : thumbnail.when(
                        data: (bytes) => bytes == null
                            ? Icon(
                                Icons.image_outlined,
                                size: 24,
                                color: accent.primary,
                              )
                            : Image.memory(
                                bytes,
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                                filterQuality: FilterQuality.medium,
                                semanticLabel:
                                    context.l10n.clipboardImageFileThumbnail,
                                errorBuilder: (_, _, _) => Icon(
                                  Icons.broken_image_outlined,
                                  size: 23,
                                  color: accent.primary,
                                ),
                              ),
                        loading: () => const Center(
                          child: SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                        error: (_, _) => Icon(
                          Icons.broken_image_outlined,
                          size: 23,
                          color: accent.primary,
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              files.length > 1 ? '$name  +${files.length - 1}' : name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ShellText.base.copyWith(fontSize: 12.5, height: 1.25),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClipboardTextTile extends StatelessWidget {
  const _ClipboardTextTile({
    required this.entry,
    required this.highlighted,
    required this.lifted,
  });

  final ClipboardHistoryEntry entry;
  final bool highlighted;
  final bool lifted;

  @override
  Widget build(BuildContext context) {
    const maxLines = 8;
    const horizontalPadding = 14.0;
    const verticalPadding = 12.0;
    const maxTileWidth = 280.0;
    final normalized = entry.preview.replaceAll(RegExp(r'\s+$'), '');
    final text = normalized.isEmpty ? ' ' : normalized;
    final style = ShellText.base.copyWith(
      color: context.shellColors.textPrimary,
      fontSize: 13,
      height: 1.38,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth = constraints.hasBoundedWidth
            ? math.min(maxTileWidth, constraints.maxWidth)
            : maxTileWidth;
        final contentWidth = math.max(1.0, tileWidth - horizontalPadding * 2);
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: maxLines,
          ellipsis: '…',
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          textWidthBasis: TextWidthBasis.longestLine,
        )..layout(maxWidth: contentWidth);
        final measuredSize = painter.size;
        painter.dispose();
        final minimumWidth = math.min(72.0, tileWidth);
        final width = (measuredSize.width + horizontalPadding * 2)
            .clamp(minimumWidth, tileWidth)
            .toDouble();
        final height = measuredSize.height + verticalPadding * 2;

        return AnimatedContainer(
          duration: Motion.cardSettle,
          curve: Motion.standard,
          width: width,
          height: height,
          padding: const EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: verticalPadding,
          ),
          decoration: _clipboardNoteDecoration(
            context,
            entry: entry,
            highlighted: highlighted,
            lifted: lifted,
          ),
          child: Text(
            text,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        );
      },
    );
  }
}

BoxDecoration _clipboardNoteDecoration(
  BuildContext context, {
  required ClipboardHistoryEntry entry,
  required bool highlighted,
  required bool lifted,
}) {
  final accent = ShellTheme.of(context).accentPalette;
  final raised = highlighted || lifted;
  final tint = entry.active
      ? 0.16
      : raised
      ? 0.11
      : 0.055;
  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color.alphaBlend(
          accent.primary.withValues(alpha: tint),
          context.shellColors.surfaceContainerLow,
        ).withValues(
          alpha: entry.active
              ? 0.62
              : raised
              ? 0.54
              : 0.44,
        ),
        Color.alphaBlend(
          accent.primary.withValues(alpha: tint * 0.3),
          context.shellColors.panelBackgroundBottom,
        ).withValues(
          alpha: entry.active
              ? 0.46
              : raised
              ? 0.38
              : 0.3,
        ),
      ],
    ),
    borderRadius: BorderRadius.circular(18),
    border: Border.all(
      color: accent.primary.withValues(
        alpha: entry.active
            ? 0.48
            : raised
            ? 0.3
            : 0.12,
      ),
    ),
  );
}

Size _clipboardImageDisplaySize(ClipboardHistoryEntry entry) {
  const maxWidth = 320.0;
  const maxHeight = 220.0;
  const minLongestSide = 72.0;
  if (entry.width <= 0 || entry.height <= 0) {
    return const Size(280, 175);
  }
  final width = entry.width.toDouble();
  final height = entry.height.toDouble();
  final fitScale = math.min(maxWidth / width, maxHeight / height);
  final minimumScale = minLongestSide / math.max(width, height);
  final scale = math.min(fitScale, math.max(1.0, minimumScale));
  return Size(width * scale, height * scale);
}

Size _fitClipboardImageSize(Size requested, BoxConstraints constraints) {
  final widthScale = constraints.hasBoundedWidth
      ? constraints.maxWidth / requested.width
      : 1.0;
  final heightScale = constraints.hasBoundedHeight
      ? constraints.maxHeight / requested.height
      : 1.0;
  final scale = math.min(1.0, math.min(widthScale, heightScale));
  return Size(requested.width * scale, requested.height * scale);
}
