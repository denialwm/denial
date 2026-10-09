import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/materials.dart';
import 'package:flutter/material.dart';

import 'localized_feedback.dart';
import 'backend.dart';
import 'controller.dart';
import 'presentation.dart';
import 'job_feedback.dart';
import 'operation_details.dart';
import 'progress_text.dart';
import 'setup_status.dart';

class SelectionPanel extends StatelessWidget {
  const SelectionPanel({
    required this.controller,
    required this.onDiscover,
    this.query = '',
    super.key,
  });
  final ManagerController controller;
  final VoidCallback onDiscover;
  final String query;

  @override
  Widget build(BuildContext context) {
    final known = {...controller.installed, ...controller.roots};
    final entries = known.entries
        .where(
          (entry) =>
              matchesPlugin({...object(entry.value), 'name': entry.key}, query),
        )
        .toList();
    final plan = object(controller.state['plan']);
    final discovery = object(plan['discovery']);
    final required =
        !controller.draft.dirty &&
            plan['selectionRevision'] == controller.selection['revision']
        ? (discovery['plugins'] as List? ?? const [])
              .cast<String>()
              .where((name) => !controller.roots.containsKey(name))
              .toList()
        : <String>[];
    return PageBody(
      children: [
        PageIntro(
          title: context.l10n.pluginsInstalledTitle,
          description: context.l10n.pluginsInstalledDescription,
        ),
        if (known.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              context.l10n.pluginsSelectedCount(controller.roots.length),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: context.applicationColors.secondary),
            ),
          ),
        if (known.isEmpty)
          EmptyState(
            icon: Icons.widgets_outlined,
            title: context.l10n.pluginsNoneInstalled,
            description: context.l10n.pluginsNoneInstalledDescription,
            action: Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                FilledButton(
                  onPressed: onDiscover,
                  child: Text(context.l10n.pluginsDiscoverAction),
                ),
                if (controller.configured)
                  TextButton(
                    onPressed: controller.busy ? null : controller.useDefaults,
                    child: Text(context.l10n.pluginsUseDefaults),
                  ),
              ],
            ),
          )
        else if (entries.isEmpty)
          EmptyState(
            icon: Icons.search_off_rounded,
            title: context.l10n.pluginsNoMatches,
            description: context.l10n.pluginsNoMatchesDescription,
          )
        else
          for (final entry in entries)
            _CollectionEntry(
              plugin: {...object(entry.value), 'name': entry.key},
              controller: controller,
            ),
        if (!controller.configured) ...[
          const SizedBox(height: 24),
          _SetupCard(controller: controller),
        ],
        if (required.isNotEmpty) ...[
          const SizedBox(height: 8),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            shape: const Border(),
            collapsedShape: const Border(),
            title: Text(context.l10n.pluginsAutomaticTitle),
            subtitle: Text(context.l10n.pluginsAutomaticDescription),
            children: [
              for (final name in required)
                ListTile(
                  leading: const Icon(Icons.link_rounded, size: 20),
                  title: Text(pluginTitle(name)),
                  subtitle: Text(
                    ((object(discovery['dependencyChains'])[name] as List? ??
                            const [])
                        .cast<String>()
                        .skip(1)
                        .map(pluginTitle)
                        .join(' → ')),
                  ),
                ),
            ],
          ),
        ],
        if (known.isNotEmpty) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onDiscover,
              icon: const Icon(Icons.explore_outlined, size: 18),
              label: Text(context.l10n.pluginsDiscoverMore),
            ),
          ),
        ],
        const SizedBox(height: 28),
        Divider(color: context.applicationColors.separator),
        _DesktopOptions(controller: controller),
      ],
    );
  }
}

class _SetupCard extends StatelessWidget {
  const _SetupCard({required this.controller});
  final ManagerController controller;
  @override
  Widget build(BuildContext context) {
    final notice = SetupNotice.fromState(controller.state);
    return PluginSurface(
      child: Semantics(
        container: true,
        liveRegion: !controller.busy,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (!controller.busy) ...[
                  const Icon(Icons.warning_amber_rounded, size: 20),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    controller.busy
                        ? context.l10n.pluginsPreparingDesktop
                        : setupTitle(context.l10n, notice),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              controller.busy
                  ? context.l10n.pluginsPreparingDescription
                  : setupDescription(context.l10n, notice),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.applicationColors.secondary,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            if (controller.busy)
              const LinearProgressIndicator()
            else
              TextButton(
                onPressed: () => controller.submit(['initialize']),
                child: Text(context.l10n.pluginsTryAgain),
              ),
          ],
        ),
      ),
    );
  }
}

class _CollectionEntry extends StatelessWidget {
  const _CollectionEntry({required this.plugin, required this.controller});
  final Map<String, Object?> plugin;
  final ManagerController controller;
  @override
  Widget build(BuildContext context) {
    final name = plugin['name']! as String;
    final selected = controller.roots.containsKey(name);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: context.applicationColors.separator),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PluginEmblem(),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pluginTitle(name),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  plugin['description'] as String? ??
                      context.l10n.pluginsFallbackDescription,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: context.applicationColors.secondary,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  selected
                      ? context.l10n.pluginsSelected
                      : context.l10n.pluginsNotSelected,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: selected
                        ? Theme.of(context).colorScheme.primary
                        : context.applicationColors.secondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Semantics(
            label: context.l10n.pluginsSwitchSemantics(pluginTitle(name)),
            child: Switch(
              value: selected,
              onChanged: controller.busy
                  ? null
                  : (enabled) => enabled
                        ? controller.enable(plugin)
                        : controller.disable(name),
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopOptions extends StatelessWidget {
  const _DesktopOptions({required this.controller});
  final ManagerController controller;
  @override
  Widget build(BuildContext context) {
    final native = object(controller.state['native']);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      shape: const Border(),
      collapsedShape: const Border(),
      title: Text(
        context.l10n.pluginsDesktopOptions,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      subtitle: Text(
        context.l10n.pluginsDesktopOptionsDescription,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            TextButton(
              onPressed: !controller.canApply
                  ? null
                  : () => controller.submit(['update']),
              child: Text(context.l10n.pluginsCheckUpdates),
            ),
            TextButton(
              onPressed:
                  controller.busy ||
                      controller.draft.dirty ||
                      !controller.configured
                  ? null
                  : () => controller.submit(['plan']),
              child: Text(context.l10n.pluginsCheckCompatibility),
            ),
            TextButton(
              onPressed: controller.busy || native['can_revert'] != true
                  ? null
                  : () => controller.submit(['revert']),
              child: Text(context.l10n.pluginsUndo),
            ),
            TextButton(
              onPressed: controller.busy || native['available'] == false
                  ? null
                  : () => controller.submit(['restore']),
              child: Text(context.l10n.pluginsRestore),
            ),
          ],
        ),
      ],
    );
  }
}

class ApplyBar extends StatelessWidget {
  const ApplyBar({required this.controller, super.key});
  final ManagerController controller;

  void showDetails(BuildContext context, String error) => showDialog<void>(
    context: context,
    builder: (_) => OperationDetailsDialog(
      error: error,
      backend: controller.backend,
      jobId: controller.startupError == null
          ? (controller.feedback.failure?['id'] as String?)
          : null,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final busy = controller.busy;
    final error = controller.error;
    final active = controller.jobs
        .where(
          (job) =>
              (job['arguments'] as Map?)?['argv'] is List &&
              {'running', 'queued'}.contains(job['phase']),
        )
        .firstOrNull;
    final progress = OperationProgress.fromJob(active);
    final issues = controller.compatibilityIssues;
    final blocked = !busy && issues.isNotEmpty;
    final failed = !busy && error != null;
    final label = blocked
        ? context.l10n.pluginsCheckSelection
        : failed
        ? controller.startupError != null
              ? context.l10n.pluginsStartupFailed
              : context.l10n.pluginsChangeFailed
        : busy
        ? progressLabel(context.l10n, progress.label)
        : controller.configured
        ? controller.draft.dirty
              ? context.l10n.pluginsSelectionChanged
              : controller.pendingRebuild != null
              ? context.l10n.pluginsPaused
              : context.l10n.pluginsPendingReady
        : context.l10n.pluginsPreparingSupport;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow =
              constraints.maxWidth < 480 ||
              MediaQuery.textScalerOf(context).scale(14) > 21;
          final status = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                failed || blocked
                    ? Icons.error_outline_rounded
                    : busy
                    ? Icons.pending_outlined
                    : Icons.tune_rounded,
                size: 22,
                color: failed || blocked
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 4),
                      if (busy)
                        ProgressText(
                          progress: progress,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: context.applicationColors.secondary,
                              ),
                        )
                      else
                        Text(
                          blocked
                              ? issues
                                    .map(
                                      (issue) => compatibilitySummary(
                                        context.l10n,
                                        issue,
                                      ),
                                    )
                                    .join('\n\n')
                              : failed
                              ? localizedFailureSummary(context.l10n, error)
                              : applyDescription(context.l10n, controller),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: context.applicationColors.secondary,
                              ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
          final actions = Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (blocked && issues.any((issue) => issue['message'] is String))
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => OperationDetailsDialog(
                      error: issues
                          .map((issue) => issue['message'])
                          .whereType<String>()
                          .join('\n\n'),
                      backend: controller.backend,
                    ),
                  ),
                  child: Text(context.l10n.pluginsViewDetails),
                ),
              if (failed)
                TextButton(
                  onPressed: () => showDetails(context, error),
                  child: Text(context.l10n.pluginsViewDetails),
                ),
              if (controller.draft.dirty)
                TextButton(
                  onPressed: busy ? null : controller.discardDraft,
                  child: Text(context.l10n.pluginsDiscard),
                ),
              if (controller.rebuildWaitsForPause)
                FilledButton(
                  onPressed: controller.switchRequested
                      ? null
                      : controller.switchNow,
                  child: Text(context.l10n.pluginsSwitchNow),
                )
              else if (controller.needsApply)
                FilledButton.icon(
                  onPressed: !controller.canSubmitApply
                      ? null
                      : () => controller.submit(controller.applyOperation),
                  icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                  iconAlignment: IconAlignment.end,
                  label: Text(applyLabel(context.l10n, controller)!),
                ),
              if (failed && controller.startupError == null)
                IconButton(
                  tooltip: context.l10n.pluginsDismissError,
                  onPressed: controller.dismissError,
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
            ],
          );
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (narrow || failed || blocked) ...[
                status,
                const SizedBox(height: 12),
                actions,
              ] else
                Row(
                  children: [
                    Expanded(child: status),
                    const SizedBox(width: 20),
                    actions,
                  ],
                ),
              if (busy) ...[
                const SizedBox(height: 14),
                LinearProgressIndicator(
                  minHeight: 4,
                  borderRadius: DenialSurfaceGeometry.borderRadiusOf(
                    context,
                    inset: 24,
                  ),
                  semanticsLabel: progressStage(context.l10n, progress),
                  // Stage counts are not an elapsed-time percentage.
                  semanticsValue: progress.total == null
                      ? context.l10n.pluginsInProgress
                      : context.l10n.pluginsStepsComplete(
                          progress.completed!,
                          progress.total!,
                        ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class BrowsePanel extends StatelessWidget {
  const BrowsePanel({
    required this.controller,
    required this.onAdd,
    this.query = '',
    super.key,
  });
  final ManagerController controller;
  final VoidCallback onAdd;
  final String query;
  @override
  Widget build(BuildContext context) {
    final catalog = object(controller.catalog['catalog']);
    final builtins = objects(controller.catalog['builtins'])
        .where((p) => matchesPlugin(p, query))
        .toList();
    final community = objects(catalog['entries'])
        .where((p) => matchesPlugin(p, query))
        .toList();
    return PageBody(
      children: [
        PageIntro(
          title: context.l10n.pluginsDiscoverTitle,
          description: context.l10n.pluginsDiscoverDescription,
        ),
        if (builtins.isEmpty && community.isEmpty && query.trim().isNotEmpty)
          EmptyState(
            icon: Icons.search_off_rounded,
            title: context.l10n.pluginsNothingFound,
            description: context.l10n.pluginsNothingFoundDescription,
          ),
        if (builtins.isNotEmpty) ...[
          SectionHeading(context.l10n.pluginsOfficial),
          PluginGrid(plugins: builtins, controller: controller, official: true),
          const SizedBox(height: 20),
        ],
        if (community.isNotEmpty || query.trim().isEmpty) ...[
          SectionHeading(
            context.l10n.pluginsCommunity,
            trailing: controller.catalog['configured'] == true
                ? IconButton(
                    tooltip: context.l10n.pluginsRefreshDiscoveries,
                    onPressed: controller.busy
                        ? null
                        : () => controller.submit(['refresh-catalog']),
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                  )
                : null,
          ),
          PluginGrid(plugins: community, controller: controller),
          if (community.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Text(
                context.l10n.pluginsNoCommunity,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: context.applicationColors.secondary,
                  height: 1.6,
                ),
              ),
            ),
        ],
        const SizedBox(height: 12),
        PluginSurface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.add_link_rounded, size: 28),
              const SizedBox(height: 16),
              Text(
                context.l10n.pluginsAddRepository,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.pluginsAddRepositoryDescription,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: context.applicationColors.secondary,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: controller.busy ? null : onAdd,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(context.l10n.pluginsAddLink),
              ),
            ],
          ),
        ),
        if ((catalog['errors'] as List? ?? []).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(context.l10n.pluginsDiscoveryFailed),
          ),
      ],
    );
  }
}

class PluginGrid extends StatelessWidget {
  const PluginGrid({
    required this.plugins,
    required this.controller,
    this.official = false,
    super.key,
  });
  final List<Map<String, Object?>> plugins;
  final ManagerController controller;
  final bool official;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns =
          constraints.maxWidth >= 660 &&
              MediaQuery.textScalerOf(context).scale(14) <= 21
          ? 2
          : 1;
      return Column(
        children: [
          for (var start = 0; start < plugins.length; start += columns)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (
                      var index = start;
                      index < start + columns;
                      index++
                    ) ...[
                      if (index != start) const SizedBox(width: 16),
                      Expanded(
                        child: index < plugins.length
                            ? PluginCard(
                                plugin: plugins[index],
                                controller: controller,
                                official: official,
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}

class PluginCard extends StatelessWidget {
  const PluginCard({
    required this.plugin,
    required this.controller,
    this.official = false,
    super.key,
  });
  final Map<String, Object?> plugin;
  final ManagerController controller;
  final bool official;
  @override
  Widget build(BuildContext context) {
    final selected = controller.roots.containsKey(plugin['name']);
    return PluginSurface(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const PluginEmblem(size: 52),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pluginTitle(plugin['name']! as String),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      official
                          ? context.l10n.pluginsByDenial
                          : context.l10n.pluginsCommunityPlugin,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.applicationColors.secondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            plugin['description'] as String? ??
                context.l10n.pluginsFallbackDescription,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: context.applicationColors.secondary,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 20),
          if (selected)
            Row(
              children: [
                Icon(
                  Icons.check_circle_outline_rounded,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Flexible(child: Text(context.l10n.pluginsSelectedDesktop)),
              ],
            )
          else
            OutlinedButton.icon(
              onPressed: controller.busy
                  ? null
                  : () => controller.enable(plugin),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(context.l10n.pluginsSelect),
            ),
        ],
      ),
    );
  }
}

class ActivityPanel extends StatelessWidget {
  const ActivityPanel({required this.controller, super.key});
  final ManagerController controller;
  @override
  Widget build(BuildContext context) => PageBody(
    children: [
      PageIntro(
        title: context.l10n.pluginsRecentActivity,
        description: context.l10n.pluginsActivityDescription,
      ),
      if (controller.jobs.isEmpty)
        EmptyState(
          icon: Icons.history_rounded,
          title: context.l10n.pluginsNoActivity,
          description: context.l10n.pluginsNoActivityDescription,
        ),
      for (final job in controller.jobs)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _ActivityEntry(job: job),
        ),
    ],
  );
}

class _ActivityEntry extends StatelessWidget {
  const _ActivityEntry({required this.job});
  final Map<String, Object?> job;
  @override
  Widget build(BuildContext context) {
    final failed = job['phase'] == 'failed' || job['phase'] == 'interrupted';
    final running = job['phase'] == 'running' || job['phase'] == 'queued';
    final color = failed
        ? Theme.of(context).colorScheme.error
        : context.applicationColors.secondary;
    return PluginSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                failed
                    ? Icons.error_outline_rounded
                    : running
                    ? Icons.pending_outlined
                    : Icons.check_circle_outline_rounded,
                size: 22,
                color: color,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      operationTitle(context.l10n, job['operation'] as String?),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      switch (job['phase']) {
                        'succeeded' => context.l10n.pluginsCompleted,
                        'failed' ||
                        'interrupted' => context.l10n.pluginsNeedsAttention,
                        'queued' => context.l10n.statusWaiting,
                        _ => context.l10n.pluginsInProgress,
                      },
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: color),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (running) ...[
            const SizedBox(height: 20),
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            ProgressText(progress: OperationProgress.fromJob(job)),
          ],
          if (job['error'] != null) ...[
            const SizedBox(height: 16),
            Text(
              localizedFailureSummary(context.l10n, job['error']! as String),
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(context.l10n.pluginsTechnicalDetails),
              children: [SelectableText(failureCause(job['error']! as String))],
            ),
          ],
        ],
      ),
    );
  }
}
