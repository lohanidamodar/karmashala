import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../agents/application/agent_providers.dart';
import '../../agents/presentation/agent_logo.dart';
import '../application/session_agent_providers.dart';

/// The mark of the agent [sessionId] runs, named on hover: what a session's
/// bar leads with. Nothing, and no width, until the agent is known.
class SessionAgentMark extends ConsumerWidget {
  const SessionAgentMark({required this.sessionId, super.key});

  /// The key the session bar's mark carries, for whoever looks for it.
  static const barKey = ValueKey('session-bar-agent');

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agentId = ref.watch(sessionAgentIdProvider(sessionId));
    if (agentId == null) return const SizedBox.shrink();
    final name = ref.watch(agentRegistryProvider).displayNameFor(agentId);
    return Padding(
      padding: const EdgeInsets.only(right: Insets.sm),
      child: Tooltip(
        message: name,
        child: Semantics(
          label: name,
          child: AgentLogo(agentId: agentId, size: UiDensity.of(context).icon),
        ),
      ),
    );
  }
}
