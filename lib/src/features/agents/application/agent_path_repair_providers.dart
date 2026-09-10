import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/discovery.dart';

/// Ambient state: what the last check of the stored agent paths established.
/// Unchecked is not the same as checked and found nothing wrong.
class AgentPathRepairController extends Notifier<AgentPathRepairReport> {
  @override
  AgentPathRepairReport build() => const AgentPathRepairReport.unchecked();

  void set(AgentPathRepairReport next) => state = next;
}

final agentPathRepairProvider =
    NotifierProvider<AgentPathRepairController, AgentPathRepairReport>(
      AgentPathRepairController.new,
    );
