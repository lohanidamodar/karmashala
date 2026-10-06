import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/automation_providers.dart';

/// "Started from webhook triage-issue" for a session an automation started;
/// nothing for one a person or an agent did.
class SessionOriginLabel extends ConsumerWidget {
  const SessionOriginLabel({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final origin = ref.watch(sessionAutomationOriginProvider(sessionId));
    if (origin == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Text(
      'Started $origin',
      key: const ValueKey('session-automation-origin'),
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
