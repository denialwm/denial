import 'package:denial_flutter_sdk/localization.dart';
import 'package:flutter/material.dart';

import 'localized_feedback.dart';
import 'backend.dart';
import 'controller.dart';
import 'presentation.dart';

class RepositoryDialog extends StatefulWidget {
  const RepositoryDialog({required this.controller, super.key});
  final ManagerController controller;
  @override
  State<RepositoryDialog> createState() => _RepositoryDialogState();
}

class _RepositoryDialogState extends State<RepositoryDialog> {
  final url = TextEditingController();
  final ref = TextEditingController();
  List<Map<String, Object?>> candidates = [];
  String? selected;
  String? error;
  bool noCandidates = false;
  bool loading = false;
  bool local = false;
  @override
  void dispose() {
    url.dispose();
    ref.dispose();
    super.dispose();
  }

  Future<void> inspect() async {
    setState(() {
      loading = true;
      error = null;
      noCandidates = false;
      candidates = [];
      selected = null;
    });
    try {
      final result = await widget.controller.backend.invoke([
        'inspect',
        url.text.trim(),
        if (local) '--local',
        if (ref.text.trim().isNotEmpty) ...['--ref', ref.text.trim()],
      ]);
      if (!mounted) return;
      setState(() {
        candidates = objects(result);
        selected = candidates.length == 1
            ? candidates.single['path']! as String
            : null;
        if (candidates.isEmpty) {
          noCandidates = true;
        }
      });
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(Icons.add_link_rounded),
    title: Text(context.l10n.pluginsBringNew),
    scrollable: true,
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.pluginsTrustDescription),
            const SizedBox(height: 20),
            TextField(
              controller: url,
              autofocus: true,
              enabled: !loading,
              decoration: InputDecoration(
                labelText: local
                    ? context.l10n.pluginsLocalDirectory
                    : context.l10n.pluginsRepositoryLink,
              ),
              onChanged: (_) => setState(() {
                selected = null;
                candidates = [];
              }),
            ),
            const SizedBox(height: 12),
            if (!local)
              ExpansionTile(
                title: Text(context.l10n.pluginsAdvancedOptions),
                tilePadding: EdgeInsets.zero,
                children: [
                  TextField(
                    controller: ref,
                    enabled: !loading,
                    decoration: InputDecoration(
                      labelText: context.l10n.pluginsGitRef,
                    ),
                    onChanged: (_) => setState(() {
                      selected = null;
                      candidates = [];
                    }),
                  ),
                ],
              ),
            ExpansionTile(
              title: Text(context.l10n.pluginsLocalDevelopment),
              tilePadding: EdgeInsets.zero,
              children: [
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.l10n.pluginsUseLocal),
                  value: local,
                  onChanged: loading
                      ? null
                      : (value) => setState(() {
                          local = value!;
                          candidates = [];
                          selected = null;
                        }),
                ),
              ],
            ),
            if (loading) const LinearProgressIndicator(),
            if (error != null || noCandidates)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: SelectableText(
                  noCandidates
                      ? context.l10n.pluginsNoCandidates
                      : localizedFailureSummary(context.l10n, error!),
                ),
              ),
            if (error != null)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(context.l10n.pluginsTechnicalDetails),
                children: [SelectableText(error!)],
              ),
            if (candidates.isNotEmpty) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: selected,
                decoration: InputDecoration(
                  labelText: context.l10n.pluginsChoose,
                ),
                isExpanded: true,
                items: [
                  for (final item in candidates)
                    DropdownMenuItem(
                      value: item['path']! as String,
                      child: Text(
                        context.l10n.pluginsCandidateLabel(
                          pluginTitle(item['name']! as String),
                          item['path']! as String,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => setState(() => selected = value),
              ),
              const SizedBox(height: 12),
              Text(context.l10n.pluginsIncludeDependencies),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.actionCancel),
      ),
      if (candidates.isEmpty)
        FilledButton(
          onPressed: loading || url.text.trim().isEmpty ? null : inspect,
          child: Text(
            loading ? context.l10n.pluginsFinding : context.l10n.pluginsFind,
          ),
        ),
      if (candidates.isNotEmpty)
        FilledButton(
          onPressed: selected == null || loading
              ? null
              : () {
                  final candidate = candidates.firstWhere(
                    (item) => item['path'] == selected,
                  );
                  widget.controller.enable({
                    ...candidate,
                    'source': {
                      'kind': local ? 'local' : 'git',
                      'location': url.text.trim(),
                      'path': selected!,
                      if (!local && ref.text.trim().isNotEmpty)
                        'ref': ref.text.trim(),
                    },
                  });
                  Navigator.pop(context);
                },
          child: Text(context.l10n.pluginsAdd),
        ),
    ],
  );
}

class ConfigurationDialog extends StatelessWidget {
  const ConfigurationDialog({required this.controller, super.key});
  final ManagerController controller;

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(Icons.extension_outlined),
    title: Text(context.l10n.pluginsYourPlugins),
    content: SizedBox(
      width: 440,
      child: Text(context.l10n.pluginsConfigurationDescription),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.pluginsDone),
      ),
    ],
  );
}
