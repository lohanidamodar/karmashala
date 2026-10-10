import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/workbench_tabs.dart' show openWorkflowsTab;
import '../application/automation_editor_state.dart';
import '../application/automation_providers.dart';

/// "Sent by automation Nightly" over a message an automation sent into a
/// session, linking to that automation.
class AutomationSentLabel extends ConsumerWidget {
  const AutomationSentLabel({required this.by, super.key});

  final AutomationAttribution by;

  void _open(WidgetRef ref) {
    final automation = ref
        .read(automationsProvider)
        .where((a) => a.id == by.automationId)
        .firstOrNull;
    openWorkflowsTab(ref);
    if (automation != null) {
      ref.read(automationEditorProvider.notifier).edit(automation);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Semantics(
      link: true,
      label: 'Sent by automation ${by.name}. Open it.',
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('automation-sent-${by.automationId}'),
        borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
        onTap: () => _open(ref),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.xs,
            vertical: Insets.xxs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppIcons.lightning,
                size: Chrome.iconAction,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: Insets.xs),
              Flexible(
                child: Text.rich(
                  TextSpan(
                    text: 'Sent by automation ',
                    children: [
                      TextSpan(
                        text: by.name,
                        style: TextStyle(
                          color: theme.colorScheme.primary,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ],
                  ),
                  style: muted,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
