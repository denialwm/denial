import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/materials.dart';
import 'package:flutter/material.dart';

String pluginTitle(String name) => name
    .replaceFirst(RegExp(r'^denial_'), '')
    .split('_')
    .where((word) => word.isNotEmpty)
    .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
    .join(' ');

String operationTitle(AppLocalizations l10n, String? operation) =>
    switch (operation) {
      'apply' || 'activate' => l10n.pluginsApply,
      'build' => l10n.pluginsBuild,
      'plan' => l10n.pluginsCheckChanges,
      'add' || 'enable' => l10n.pluginsEnable,
      'remove' => l10n.pluginsDisable,
      'update' => l10n.pluginsUpdate,
      'rebuild' => l10n.pluginsRebuild,
      'restore' => l10n.pluginsRestore,
      'revert' => l10n.pluginsUndo,
      'prepare' => l10n.pluginsSetup,
      'defaults' => l10n.pluginsChooseDefaults,
      'refresh-catalog' => l10n.pluginsRefreshDiscoveries,
      _ => l10n.pluginsActivityFallback,
    };

class PageIntro extends StatelessWidget {
  const PageIntro({required this.title, required this.description, super.key});
  final String title;
  final String description;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: Theme.of(context).textTheme.headlineSmall
            ?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.4),
      ),
      const SizedBox(height: 8),
      Text(
        description,
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(color: context.applicationColors.secondary, height: 1.5),
      ),
      const SizedBox(height: 24),
    ],
  );
}

class PluginSurface extends StatelessWidget {
  const PluginSurface({
    required this.child,
    this.padding = const EdgeInsets.all(20),
    super.key,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => DenialMaterial(
    role: DenialMaterialRole.card,
    child: Builder(
      builder: (context) {
        final edges = padding.resolve(Directionality.of(context));
        final inset = [
          edges.left,
          edges.top,
          edges.right,
          edges.bottom,
        ].reduce((a, b) => a < b ? a : b);
        return Padding(
          padding: padding,
          child: DenialSurfaceGeometry(
            radius: DenialSurfaceGeometry.nestedRadius(context, inset: inset),
            child: child,
          ),
        );
      },
    ),
  );
}

class PluginEmblem extends StatelessWidget {
  const PluginEmblem({
    this.icon = Icons.extension_rounded,
    this.size = 46,
    super.key,
  });
  final IconData icon;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: context.applicationColors.control,
      borderRadius: DenialSurfaceGeometry.borderRadiusOf(context),
    ),
    child: Icon(
      icon,
      size: size * .48,
      color: context.applicationColors.foreground,
    ),
  );
}

class SectionHeading extends StatelessWidget {
  const SectionHeading(this.title, {this.trailing, super.key});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 16),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    required this.description,
    this.action,
    super.key,
  });
  final IconData icon;
  final String title;
  final String description;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
    child: Column(
      children: [
        PluginEmblem(icon: icon, size: 52),
        const SizedBox(height: 24),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Text(
            description,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: context.applicationColors.secondary,
              height: 1.6,
            ),
          ),
        ),
        if (action != null) ...[const SizedBox(height: 24), action!],
      ],
    ),
  );
}

class PageBody extends StatelessWidget {
  const PageBody({required this.children, super.key});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => DenialContentPane(
    sliversBuilder: (context, width) {
      final inset = width < 560 ? 24.0 : 32.0;
      final horizontal = ((width - 920) / 2).clamp(inset, double.infinity);
      return [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(horizontal, 28, horizontal, 32),
          sliver: SliverList.builder(
            itemCount: children.length,
            itemBuilder: (context, index) => children[index],
          ),
        ),
      ];
    },
  );
}

bool matchesPlugin(Map<String, Object?> plugin, String query) {
  final needle = query.trim().toLowerCase();
  return needle.isEmpty ||
      '${plugin['name']} ${pluginTitle(plugin['name'] as String? ?? '')} ${plugin['description'] ?? ''}'
          .toLowerCase()
          .contains(needle);
}
