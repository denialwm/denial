import 'package:flutter/widgets.dart';

import '../../l10n/generated/app_localizations.dart';

/// Installs Denial's generated localizations without introducing a
/// [WidgetsApp] or [MaterialApp] above the compositor scene.
///
/// The platform locale is resolved against the generated locale catalog and
/// observed for changes. Unsupported locales fall back through Flutter's
/// standard locale resolution, which currently selects English.
class DenialLocalizationScope extends StatefulWidget {
  const DenialLocalizationScope({
    required this.child,
    this.locale,
    super.key,
  });

  final Widget child;

  /// An explicit locale for tests or a future user preference. When omitted,
  /// the scope follows the platform's ordered locale list.
  final Locale? locale;

  @override
  State<DenialLocalizationScope> createState() =>
      _DenialLocalizationScopeState();
}

class _DenialLocalizationScopeState extends State<DenialLocalizationScope>
    with WidgetsBindingObserver {
  late Locale _effectiveLocale;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _effectiveLocale = _resolveLocale();
  }

  @override
  void didUpdateWidget(covariant DenialLocalizationScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.locale != widget.locale) {
      _updateLocale();
    }
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    if (widget.locale == null) {
      _updateLocale(locales);
    }
  }

  Locale _resolveLocale([List<Locale>? platformLocales]) {
    final explicitLocale = widget.locale;
    if (explicitLocale != null) {
      return basicLocaleListResolution(
        <Locale>[explicitLocale],
        AppLocalizations.supportedLocales,
      );
    }
    return basicLocaleListResolution(
      platformLocales ?? WidgetsBinding.instance.platformDispatcher.locales,
      AppLocalizations.supportedLocales,
    );
  }

  void _updateLocale([List<Locale>? platformLocales]) {
    final nextLocale = _resolveLocale(platformLocales);
    if (nextLocale != _effectiveLocale) {
      setState(() => _effectiveLocale = nextLocale);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Localizations(
      locale: _effectiveLocale,
      delegates: AppLocalizations.localizationsDelegates,
      child: Builder(
        builder: (context) => Directionality(
          textDirection: WidgetsLocalizations.of(context).textDirection,
          child: widget.child,
        ),
      ),
    );
  }
}

extension DenialLocalizationsBuildContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
