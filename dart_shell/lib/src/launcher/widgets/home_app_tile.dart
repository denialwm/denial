part of 'home_tiles.dart';

class _HomeAppTile extends StatefulWidget {
  const _HomeAppTile({
    required this.name,
    required this.iconPath,
    required this.icon,
    required this.onTap,
  });

  final String name;
  final String? iconPath;
  final IconData? icon;
  final ValueChanged<Rect>? onTap;

  @override
  State<_HomeAppTile> createState() => _HomeAppTileState();
}

class _HomeAppTileState extends State<_HomeAppTile> {
  final _iconKey = GlobalKey();

  void _launch() {
    final render = _iconKey.currentContext?.findRenderObject();
    if (render is! RenderBox || !render.hasSize) return;
    widget.onTap?.call(
      MatrixUtils.transformRect(
        render.getTransformTo(null),
        Offset.zero & render.size,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: widget.onTap != null,
      label: widget.name,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap == null ? null : _launch,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            SizedBox.square(
              dimension: 92,
              child: Center(
                child: SizedBox.square(
                  key: _iconKey,
                  dimension: 85,
                  child: widget.icon == null
                      ? AppIconImage(iconPath: widget.iconPath)
                      : ExcludeSemantics(
                          child: Icon(
                            widget.icon,
                            size: 72,
                            color: ShellTheme.of(context).accentPalette.primary,
                          ),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 9),
            Text(
              widget.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: ShellMediaColors.lightForeground,
                fontSize: 13,
                height: 1.06,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
                shadows: [
                  Shadow(
                    color: ShellMediaColors.shadow,
                    blurRadius: 8,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
