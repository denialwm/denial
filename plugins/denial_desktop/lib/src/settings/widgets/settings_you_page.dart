import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';

import '../../profile/desktop_profile.dart';
import '../../profile/profile_avatar.dart';
import '../../profile/profile_image.dart';
import 'settings_controls.dart';

class SettingsYouPage extends ConsumerStatefulWidget {
  const SettingsYouPage({this.onPickImage, super.key});
  final ProfileImagePicker? onPickImage;

  @override
  ConsumerState<SettingsYouPage> createState() => _SettingsYouPageState();
}

class _SettingsYouPageState extends ConsumerState<SettingsYouPage> {
  final _name = TextEditingController();
  DesktopProfile _saved = const DesktopProfile();
  bool _dirty = false;
  bool _busy = false;
  String? _error;
  bool _savedNotice = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual(desktopProfileProvider, (_, next) {
      final profile = next.value;
      if (profile != null && !_busy && mounted) {
        setState(() {
          _saved = profile;
          if (!_dirty) _name.text = profile.displayName;
        });
      }
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _edit() => setState(() {
    _dirty = true;
    _error = null;
    _savedNotice = false;
  });

  Future<void> _chooseImage() async {
    final picker = widget.onPickImage;
    if (picker == null || _busy) return;
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _error = null;
      _savedNotice = false;
    });
    Uint8List? bytes;
    try {
      final path = await picker(
        title: l10n.settingsYouChoosePhoto,
        cancelLabel: l10n.actionCancel,
        chooseLabel: l10n.settingsYouChoosePhoto,
      );
      if (path == null || !mounted) return;
      bytes = await prepareProfileImage(path);
      if (!mounted) return;
      final profile = await ref
          .read(desktopProfileStoreProvider)
          .save(avatarPng: bytes);
      if (mounted) setState(() => _saved = profile);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = bytes == null
              ? l10n.settingsYouImageError
              : l10n.settingsYouSaveError,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetImage() async {
    if (_busy) return;
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final profile = await ref
          .read(desktopProfileStoreProvider)
          .save(removeAvatar: true);
      if (mounted) setState(() => _saved = profile);
    } catch (_) {
      if (mounted) setState(() => _error = l10n.settingsYouSaveError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy || !_dirty) return;
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _error = null;
      _savedNotice = false;
    });
    try {
      final profile = await ref
          .read(desktopProfileStoreProvider)
          .save(displayName: _name.text);
      if (!mounted) return;
      setState(() {
        _saved = profile;
        _name.text = profile.displayName;
        _dirty = false;
        _savedNotice = true;
      });
    } catch (_) {
      if (mounted) setState(() => _error = l10n.settingsYouSaveError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final profile = ref.watch(desktopProfileProvider);
    final account =
        ref.watch(desktopAccountNameProvider) ?? l10n.desktopCurrentUser;
    final previewName = _name.text.trim().isEmpty ? account : _name.text.trim();
    final theme = Theme.of(context);
    final imagePath = ref.read(desktopProfileStoreProvider).avatarPath(_saved);
    final content = profile.isLoading && !profile.hasValue
        ? const Center(child: CircularProgressIndicator())
        : SettingsCardGroup(
            children: [
              if (profile.hasError && !profile.hasValue)
                SettingsCardPadding(
                  child: Column(
                    children: [
                      Text(
                        l10n.settingsYouLoadError,
                        style: theme.textTheme.bodyMedium,
                      ),
                      TextButton(
                        onPressed: () => ref.invalidate(desktopProfileProvider),
                        child: Text(l10n.commonRetry),
                      ),
                    ],
                  ),
                )
              else ...[
                Container(
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    borderRadius: context.shellTheme.borderRadius(24),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        theme.colorScheme.primary.withValues(alpha: .16),
                        theme.colorScheme.primary.withValues(alpha: .02),
                      ],
                    ),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final avatar = ProfileAvatar(path: imagePath, size: 104);
                      final identity = Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            previewName,
                            style: theme.textTheme.headlineSmall,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            l10n.settingsYouPreview,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      );
                      return constraints.maxWidth < 400
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                avatar,
                                const SizedBox(height: 20),
                                identity,
                              ],
                            )
                          : Row(
                              children: [
                                avatar,
                                const SizedBox(width: 24),
                                Expanded(child: identity),
                              ],
                            );
                    },
                  ),
                ),
                SettingsCardPadding(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: _busy || widget.onPickImage == null
                                ? null
                                : _chooseImage,
                            icon: const Icon(
                              Icons.add_photo_alternate_outlined,
                            ),
                            label: Text(l10n.settingsYouChoosePhoto),
                          ),
                          TextButton(
                            onPressed: _busy || imagePath == null
                                ? null
                                : _resetImage,
                            child: Text(l10n.settingsYouDefaultPhoto),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _name,
                        enabled: !_busy,
                        maxLength: 80,
                        textInputAction: TextInputAction.done,
                        decoration: InputDecoration(
                          labelText: l10n.settingsYouDisplayName,
                          hintText: account,
                          helperText: l10n.settingsYouNameHint,
                          helperMaxLines: 3,
                        ),
                        onChanged: (_) => _edit(),
                        onSubmitted: (_) => _save(),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          FilledButton.icon(
                            onPressed: _busy || !_dirty ? null : _save,
                            icon: const Icon(Icons.check_rounded),
                            label: Text(l10n.settingsYouSave),
                          ),
                          TextButton(
                            onPressed: _busy || _name.text.isEmpty
                                ? null
                                : () {
                                    _name.clear();
                                    _edit();
                                  },
                            child: Text(l10n.settingsYouAccountName),
                          ),
                          if (_savedNotice)
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                l10n.settingsYouSaved,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            _error!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.error,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          );
    return SettingsPageScaffold(
      title: context.l10n.settingsNavigationYou,
      description: context.l10n.settingsYouDescription,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final inset = settingsContentInset(constraints.maxWidth);
          return SingleChildScrollView(
            key: const PageStorageKey<String>('settings-page-you'),
            padding: EdgeInsets.fromLTRB(inset, 20, inset, 32),
            child: content,
          );
        },
      ),
    );
  }
}
