import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/tokens.dart';
import 'package:agent_cli/descriptors.dart';
import '../../agents/application/agent_model_catalog_providers.dart';
import '../../agents/presentation/model_picker.dart';
import '../application/settings_controller.dart';
import 'settings_catalog.dart';
import 'settings_section.dart';
import 'settings_notice.dart';

/// Settings → Agents and accounts → Default model: the model new sessions on
/// each agent start on, read live so a session that never chose moves when this
/// moves. "Let the agent choose" is the shipped setting and passes no
/// `--model`.
class DefaultModelSection extends ConsumerWidget {
  const DefaultModelSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    // An agent nobody has recorded models for gets no card: a menu of guesses
    // is worse than no menu.
    final descriptors = [
      for (final descriptor in AgentRegistry.builtIn.descriptors)
        if (descriptor.launch.model.isKnown) descriptor,
    ];
    if (descriptors.isEmpty) return const SizedBox.shrink();
    return SettingsSection(
      title: SettingsAnchor.defaultModel.heading,
      child: Column(
        children: [
          for (final descriptor in descriptors)
            _ModelCard(
              descriptor: descriptor,
              support: ref.watch(agentModelSupportProvider(descriptor.id)),
              selected: settings.defaultModelFor(descriptor.id),
              onChanged: (choice) =>
                  controller.setDefaultModel(descriptor.id, choice.modelId),
            ),
        ],
      ),
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.descriptor,
    required this.support,
    required this.selected,
    required this.onChanged,
  });

  final AgentDescriptor descriptor;
  final AgentModelSupport support;
  final String? selected;
  final ValueChanged<ModelChoice> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blocked = modelNotSettableReason(descriptor);
    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  descriptor.displayName,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              ModelPicker(
                options: modelOptionsFor(
                  descriptor,
                  current: selected,
                  support: support,
                ),
                selected: selected,
                onChanged: onChanged,
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          // Says which way the precedence runs, exactly as the permission
          // card does: this is where a session starts **until it chooses**.
          Text(
            'Defaults only: a model picked on a session keeps it.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          // Said on the card and not only inside the menu: a default this CLI
          // can never be told would otherwise look like it was in force.
          if (blocked != null)
            Padding(
              padding: const EdgeInsets.only(top: Insets.sm),
              child: SettingsNotice(
                tone: SettingsNoticeTone.danger,
                message: blocked,
              ),
            ),
        ],
      ),
    );
  }
}
