import 'package:denial_flutter_sdk/localization.dart';

import 'localized_feedback.dart';

import 'package:denial_flutter_sdk/materials.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'backend.dart';
import 'controller.dart';
import 'dialogs.dart';
import 'panels.dart';
import 'navigation.dart';

class ManagerPage extends StatefulWidget {
  const ManagerPage({super.key});
  @override
  State<ManagerPage> createState() => _ManagerPageState();
}

class _ManagerPageState extends State<ManagerPage> {
  late final controller = ManagerController(PluginBackend())..start();
  final search = TextEditingController();
  final searchFocus = FocusNode();
  int destination = 0;

  @override
  void dispose() {
    search.dispose();
    searchFocus.dispose();
    controller.dispose();
    super.dispose();
  }

  void addPlugin() => showDialog<void>(
    context: context,
    builder: (_) => RepositoryDialog(controller: controller),
  );

  void select(int value) => setState(() {
    destination = value;
    search.clear();
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Material(
      // The frame reveals Denial above a continuous opaque content surface.
      color: Colors.transparent,
      child: SafeArea(
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
              if (destination == 2) select(0);
              searchFocus.requestFocus();
            },
            const SingleActivator(
              LogicalKeyboardKey.digit1,
              control: true,
            ): () =>
                select(0),
            const SingleActivator(
              LogicalKeyboardKey.digit2,
              control: true,
            ): () =>
                select(1),
            const SingleActivator(
              LogicalKeyboardKey.digit3,
              control: true,
            ): () =>
                select(2),
          },
          child: FocusTraversalGroup(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact =
                    constraints.maxWidth < 800 ||
                    MediaQuery.textScalerOf(context).scale(14) > 21;
                void preferences() => showDialog<void>(
                  context: context,
                  builder: (_) => ConfigurationDialog(controller: controller),
                );
                final navigation = PluginNavigation(
                  selected: destination,
                  compact: compact,
                  onSelected: select,
                  onPreferences: controller.busy ? null : preferences,
                );
                final toolbar = PluginToolbar(
                  destination: destination,
                  search: search,
                  searchFocus: searchFocus,
                  onSearch: () => setState(() {}),
                  onAdd: controller.busy ? null : addPlugin,
                  onRefresh: controller.refresh,
                  onPreferences: controller.busy ? null : preferences,
                  applyLabel: applyLabel(context.l10n, controller),
                  onApply: !controller.canSubmitApply
                      ? null
                      : () => controller.submit(controller.applyOperation),
                );
                final page = controller.loading
                    ? DenialContentPane(
                        sliversBuilder: (context, width) => const [
                          SliverFillRemaining(
                            child: Center(child: CircularProgressIndicator()),
                          ),
                        ],
                      )
                    : switch (destination) {
                        0 => SelectionPanel(
                          controller: controller,
                          query: search.text,
                          onDiscover: () => select(1),
                        ),
                        1 => BrowsePanel(
                          controller: controller,
                          query: search.text,
                          onAdd: addPlugin,
                        ),
                        _ => ActivityPanel(controller: controller),
                      };
                final footer = Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!controller.loading &&
                        (controller.busy ||
                            controller.needsApply ||
                            controller.compatibilityIssues.isNotEmpty ||
                            controller.error != null))
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                        child: DenialMaterial(
                          role: DenialMaterialRole.toolbar,
                          floating: true,
                          inset: 16,
                          child: ApplyBar(controller: controller),
                        ),
                      ),
                  ],
                );
                return DenialApplicationFrame(
                  compact: compact,
                  navigation: navigation,
                  toolbar: toolbar,
                  footer: footer,
                  content: DenialContentSwitcher(
                    contentKey: ValueKey(destination),
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 160),
                    child: page,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
}
