import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import 'package:agent_cli/descriptors.dart';
import '../../agents/presentation/model_picker.dart';
import '../application/settings_controller.dart';
import 'agent_label.dart';
import 'settings_section.dart';

/// Settings → Agents → DEFAULT MODEL: the model new sessions on each agent
/// start on.
///
/// The permission defaults' twin, one field over, and stored the same way: a
/// per-agent preference the launcher reads live, so a session that never
/// chose moves when this moves and a session that chose does not.
///
/// **"Let the agent choose" is a real setting and the shipped one.** It passes
/// no `--model` at all, which is what every session ran under before this
/// existed; an agent is never forced to name a model here.
class DefaultModelSection extends ConsumerWidget {
  const DefaultModelSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    // An agent nobody has recorded models for gets no card, for the reason
    // `ModelChip` gives about drawing no chip: a menu of guesses is worse than
    // no menu.
    final descriptors = [
      for (final descriptor in AgentRegistry.builtIn.descriptors)
        if (descriptor.launch.model.isKnown) descriptor,
    ];
    if (descriptors.isEmpty) return const SizedBox.shrink();
    return SettingsSection(
      title: 'DEFAULT MODEL',
      child: Column(
        children: [
          for (final descriptor in descriptors)
            _ModelCard(
              descriptor: descriptor,
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
    required this.selected,
    required this.onChanged,
  });

  final AgentDescriptor descriptor;
  final String? selected;
  final ValueChanged<ModelChoice> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blocked = modelNotSettableReason(descriptor);
    return Card(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      child: Padding(
        padding: const EdgeInsets.all(Insets.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    agentLabel(descriptor.id),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                ModelPicker(
                  options: modelOptionsFor(descriptor),
                  selected: selected,
                  onChanged: onChanged,
                ),
              ],
            ),
            const SizedBox(height: Insets.xs),
            // Says which way the precedence runs, exactly as the permission
            // card does: this is where a session starts **until it chooses**.
            Text(
              'The model new sessions start on, for sessions that have not '
              'chosen one of their own. A model picked on a session keeps that '
              'session, even after this changes.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            // Said on the card and not only inside the menu: a default this CLI
            // can never be told would otherwise look like it was in force.
            if (blocked != null)
              Padding(
                padding: const EdgeInsets.only(top: Insets.sm),
                child: Row(
                  children: [
                    Icon(
                      AppIcons.warningCircle,
                      size: Chrome.icon,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: Insets.xs),
                    Expanded(
                      child: Text(
                        blocked,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
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
