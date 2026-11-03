part of 'notification_banner.dart';

/// A notification row's entrance over cached glass, from 0 to 1.
///
/// The row scales and fades in. Fading the row through an opacity layer
/// would render it offscreen on every frame, and scaling its text would
/// rasterize every glyph again at each new scale. Instead its glass fades in
/// its own shader, and everything else draws through [revealed]: a snapshot
/// that scales and fades as an image until the entrance completes.
class NotificationReveal extends InheritedWidget {
  const NotificationReveal({
    super.key,
    required this.reveal,
    required super.child,
  });

  final Animation<double> reveal;

  static Animation<double>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NotificationReveal>()?.reveal;

  /// [child] through the entrance's snapshot, if a row is revealing.
  static Widget revealed(BuildContext context, Widget child) {
    final reveal = maybeOf(context);
    return reveal == null ? child : FadeSnapshot(opacity: reveal, child: child);
  }

  @override
  bool updateShouldNotify(NotificationReveal oldWidget) =>
      oldWidget.reveal != reveal;
}
