import 'package:riverpod/riverpod.dart';

import '../domain/agent_path_repair.dart';

/// Ambient state: what the last check of the stored agent paths established.
///
/// Written by whoever ran it — the startup check in `AppLifecycle`, and
/// Settings' "Detect agents" — so both surfaces read one reading rather than
/// keeping two that can disagree. The initial value says nothing has been
/// checked, which is not the same as a check that found nothing wrong
/// (CLAUDE.md §19).
class AgentPathRepairController extends Notifier<AgentPathRepairReport> {
  @override
  AgentPathRepairReport build() => const AgentPathRepairReport.unchecked();

  void set(AgentPathRepairReport next) => state = next;
}

final agentPathRepairProvider =
    NotifierProvider<AgentPathRepairController, AgentPathRepairReport>(
      AgentPathRepairController.new,
    );
