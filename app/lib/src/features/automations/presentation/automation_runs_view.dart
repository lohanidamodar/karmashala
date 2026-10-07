import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../terminal/presentation/session_status.dart' show describeAge;
import '../application/automation_providers.dart';

/// Every run across every automation, newest first.
class AutomationRunsView extends ConsumerWidget {
  const AutomationRunsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runs = ref.watch(allAutomationRunsProvider);
    final now = ref.watch(clockProvider).nowUtc();
    final data = ref.watch(automationsDataProvider);
    final theme = Theme.of(context);
    if (runs.isEmpty) {
      return const PanePlaceholder(
        icon: AppIcons.lightning,
        message: 'No automation has run yet.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: Insets.sm),
      itemCount: runs.length,
      itemBuilder: (context, index) {
        final run = runs[index];
        return ListTile(
          key: ValueKey(run.id),
          dense: true,
          title: Text(data.getById(run.automationId)?.name ?? 'Deleted'),
          subtitle: Text(
            run.reason,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(
            '${run.state.label} · ${describeAge(run.firedAt, now: now)}',
            style: theme.textTheme.bodySmall,
          ),
        );
      },
    );
  }
}
