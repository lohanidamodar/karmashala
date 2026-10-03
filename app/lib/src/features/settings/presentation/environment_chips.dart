import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../environments/application/environments_controller.dart';

/// A quiet pill beside a name: an environment, a row's origin.
class SettingsChip extends StatelessWidget {
  const SettingsChip({required this.label, this.tooltip, super.key});

  final String label;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: scheme.onSecondaryContainer),
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}

/// Where an agent is installed, one chip per machine, wrapping on a narrow
/// row. Draws nothing for no machines: the row's own line says so.
class EnvironmentChips extends ConsumerWidget {
  const EnvironmentChips({required this.environmentIds, super.key});

  final Iterable<String> environmentIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ids = environmentIds.toSet();
    if (ids.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: Insets.xs,
      runSpacing: Insets.xs,
      children: [
        for (final id in ids)
          SettingsChip(
            label: ref.watch(environmentLabelForIdProvider(id)),
            tooltip:
                'Installed on ${ref.watch(environmentLabelForIdProvider(id))}',
          ),
      ],
    );
  }
}
