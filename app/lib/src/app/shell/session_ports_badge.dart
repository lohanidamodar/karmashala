import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/running/application/running_providers.dart';
import '../../features/running/domain/running_groups.dart';
import 'workbench_tabs.dart' show openRunningTab;

/// **Ports (N)** on the session bar: what the session's panes listen on, as
/// the last Running reading found it — nothing is read for the badge — and
/// the way to Running, filtered to the session. Nothing, and no width, at 0.
class SessionPortsBadge extends ConsumerWidget {
  const SessionPortsBadge({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reading = ref.watch(runningProvider.select((s) => s.reading));
    if (reading == null) return const SizedBox.shrink();
    final ports = portsOfSession(reading, sessionId);
    if (ports.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final count = ports.length;
    final tooltip =
        '${count == 1 ? '1 port' : '$count ports'}: '
        '${ports.map((p) => ':${p.port.port}').join(' ')}. Opens Running.';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
      child: Semantics(
        button: true,
        label: tooltip,
        excludeSemantics: true,
        child: Tooltip(
          message: tooltip,
          child: InkWell(
            key: const ValueKey('session-ports-badge'),
            onTap: () => openRunningTab(ref, sessionId: sessionId),
            borderRadius: BorderRadius.circular(Radii.sm),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.sm,
                vertical: 3,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.sm),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    AppIcons.globe,
                    size: Chrome.iconSmall,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: Insets.xs),
                  Text(
                    '$count',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
