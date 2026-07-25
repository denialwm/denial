import 'package:flutter/material.dart';

import '../../localization/denial_localizations.dart';
import '../../theme/shell_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/denial_wordmark.dart';

const settingsAboutWordmarkKey = ValueKey<String>('settings-about-wordmark');

class SettingsAboutPage extends StatelessWidget {
  const SettingsAboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: context.l10n.settingsAboutPageSemanticsLabel,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final horizontalPadding = constraints.maxWidth < 600 ? 20.0 : 36.0;
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              28,
              horizontalPadding,
              40,
            ),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: const Column(
                  children: [
                    _AboutHero(),
                    SizedBox(height: 28),
                    _AboutDescription(),
                    SizedBox(height: 28),
                    _AboutCredit(),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AboutHero extends StatelessWidget {
  const _AboutHero();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final accent = ShellTheme.of(context).accent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 30),
      child: Column(
        children: [
          ConstrainedBox(
            key: settingsAboutWordmarkKey,
            constraints: const BoxConstraints(maxWidth: 420),
            child: AspectRatio(
              aspectRatio: denialWordmarkAspectRatio,
              child: DenialWordmark(
                semanticsLabel: l10n.settingsAboutLogoSemanticsLabel,
              ),
            ),
          ),
          Text(
            l10n.settingsAboutTagline,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: ShellColors.textPrimary,
              fontSize: 22,
              height: 1.2,
              fontWeight: FontWeight.w800,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 18),
          DecoratedBox(
            decoration: BoxDecoration(
              color: accent.withAlpha(26),
              borderRadius: BorderRadius.circular(ShellRadii.chip),
              border: Border.all(color: accent.withAlpha(76)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              child: Text(
                l10n.settingsAboutBelief,
                textAlign: TextAlign.center,
                style: ShellText.cardTitle.copyWith(
                  color: accent,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutDescription extends StatelessWidget {
  const _AboutDescription();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final bodyStyle = ShellText.base.copyWith(
      color: ShellColors.textSecondary,
      fontSize: 15,
      height: 1.55,
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 660),
      child: Column(
        children: [
          Text(
            l10n.settingsAboutDescription,
            textAlign: TextAlign.center,
            style: bodyStyle,
          ),
          const SizedBox(height: 12),
          Text(
            l10n.settingsAboutArchitecture,
            textAlign: TextAlign.center,
            style: bodyStyle,
          ),
        ],
      ),
    );
  }
}

class _AboutCredit extends StatelessWidget {
  const _AboutCredit();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final accent = ShellTheme.of(context).accent;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
      child: Column(
        children: [
          Icon(Icons.person_outline_rounded, color: accent, size: 24),
          const SizedBox(height: 10),
          Text(
            l10n.settingsAboutCreditLabel,
            textAlign: TextAlign.center,
            style: ShellText.cardTitle.copyWith(
              color: ShellColors.textTertiary,
              fontSize: 10,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            l10n.settingsAboutCreditName,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: ShellColors.textPrimary,
              fontSize: 21,
              fontWeight: FontWeight.w800,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 9),
          Text(
            l10n.settingsAboutCollaboration,
            textAlign: TextAlign.center,
            style: ShellText.base.copyWith(
              color: ShellColors.textSecondary,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
