import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/materials.dart';
import 'package:flutter/material.dart';

List<(IconData, String)> destinations(BuildContext context) => [
  (Icons.widgets_outlined, context.l10n.pluginsInstalled),
  (Icons.explore_outlined, context.l10n.pluginsDiscover),
  (Icons.history_rounded, context.l10n.pluginsActivity),
];

class PluginNavigation extends StatelessWidget {
  const PluginNavigation({
    required this.selected,
    required this.compact,
    required this.onSelected,
    required this.onPreferences,
    super.key,
  });
  final int selected;
  final bool compact;
  final ValueChanged<int> onSelected;
  final VoidCallback? onPreferences;

  Widget item(BuildContext context, int index) => Semantics(
    selected: index == selected,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: TextButton(
        onPressed: () => onSelected(index),
        style: TextButton.styleFrom(
          foregroundColor: context.applicationColors.foreground,
          backgroundColor: index == selected
              ? context.applicationColors.foreground.withValues(alpha: .12)
              : null,
          alignment: Alignment.centerLeft,
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: DenialSurfaceGeometry.borderRadiusOf(
              context,
              inset: 12,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
          children: [
            Icon(destinations(context)[index].$1, size: 19),
            const SizedBox(width: 12),
            Text(
              destinations(context)[index].$2,
              style: TextStyle(
                fontWeight: index == selected
                    ? FontWeight.w600
                    : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => DenialMaterial(
    role: DenialMaterialRole.sidebar,
    floating: true,
    child: Builder(
      builder: (context) {
        if (compact) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                for (var i = 0; i < destinations(context).length; i++)
                  item(context, i),
              ],
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 20, 28),
              child: Row(
                children: [
                  const Icon(Icons.extension_outlined, size: 23),
                  const SizedBox(width: 12),
                  Text(
                    context.l10n.pluginsTitle,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      letterSpacing: -.3,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
                    child: Text(
                      context.l10n.pluginsLibrary,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: context.applicationColors.secondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  for (var i = 0; i < destinations(context).length; i++)
                    item(context, i),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: context.applicationColors.secondary,
                  alignment: Alignment.centerLeft,
                  minimumSize: const Size(44, 44),
                ),
                onPressed: onPreferences,
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: Text(context.l10n.pluginsPreferences),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class PluginToolbar extends StatelessWidget {
  const PluginToolbar({
    required this.destination,
    required this.search,
    required this.searchFocus,
    required this.onSearch,
    required this.onAdd,
    required this.onRefresh,
    required this.onPreferences,
    required this.onApply,
    required this.applyLabel,
    super.key,
  });
  final int destination;
  final TextEditingController search;
  final FocusNode searchFocus;
  final VoidCallback onSearch;
  final VoidCallback? onAdd;
  final VoidCallback onRefresh;
  final VoidCallback? onPreferences;
  final VoidCallback? onApply;
  final String? applyLabel;

  Widget searchField(BuildContext context) => TextField(
    controller: search,
    focusNode: searchFocus,
    onChanged: (_) => onSearch(),
    decoration: InputDecoration(
      hintText: destination == 0
          ? context.l10n.pluginsSearchInstalled
          : context.l10n.pluginsSearch,
      prefixIcon: const Icon(Icons.search_rounded, size: 18),
      suffixIcon: search.text.isEmpty
          ? null
          : IconButton(
              tooltip: context.l10n.pluginsClearSearch,
              onPressed: () {
                search.clear();
                onSearch();
              },
              icon: const Icon(Icons.close_rounded, size: 16),
            ),
      filled: false,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: DenialSurfaceGeometry.borderRadiusOf(context),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: DenialSurfaceGeometry.borderRadiusOf(context),
        borderSide: BorderSide.none,
      ),
    ),
  );

  Widget actionGroup(BuildContext context) => DenialMaterial(
    role: DenialMaterialRole.toolbar,
    floating: true,
    inset: DenialApplicationFrame.defaultInset,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: context.l10n.pluginsAddTooltip,
            child: TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: context.applicationColors.foreground,
                minimumSize: const Size(44, 44),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded, size: 19),
              label: Text(context.l10n.pluginsAddToolbar),
            ),
          ),
          SizedBox(
            height: 18,
            child: VerticalDivider(
              width: 12,
              color: context.applicationColors.separator,
            ),
          ),
          PopupMenuButton<String>(
            tooltip: context.l10n.pluginsMoreActions,
            icon: const Icon(Icons.more_horiz_rounded, size: 21),
            onSelected: (value) {
              switch (value) {
                case 'refresh':
                  onRefresh();
                case 'preferences':
                  onPreferences?.call();
                case 'apply':
                  onApply?.call();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'refresh',
                child: Text(context.l10n.pluginsRefresh),
              ),
              if (applyLabel != null)
                PopupMenuItem(
                  value: 'apply',
                  enabled: onApply != null,
                  child: Text(applyLabel!),
                ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'preferences',
                enabled: onPreferences != null,
                child: Text(context.l10n.pluginsPreferences),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget searchGroup(BuildContext context) => DenialMaterial(
    role: DenialMaterialRole.toolbar,
    floating: true,
    inset: DenialApplicationFrame.defaultInset,
    child: Builder(builder: searchField),
  );

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(DenialApplicationFrame.defaultInset),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final scaledText = MediaQuery.textScalerOf(context).scale(14) / 14;
        final inlineSearch = constraints.maxWidth >= 440 * scaledText;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (inlineSearch && destination != 2) ...[
                  Expanded(
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 320),
                        child: searchGroup(context),
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                ] else
                  const Spacer(),
                actionGroup(context),
              ],
            ),
            if (!inlineSearch && destination != 2) ...[
              const SizedBox(height: 12),
              searchGroup(context),
            ],
          ],
        );
      },
    ),
  );
}
