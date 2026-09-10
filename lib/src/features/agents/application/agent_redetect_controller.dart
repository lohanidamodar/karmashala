import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/discovery.dart';
import 'agent_installations_controller.dart';
import 'agent_path_repair_providers.dart';

/// What the last re-detection did, for the control that started it.
class AgentRedetectState {
  const AgentRedetectState({
    this.busy = false,
    this.report,
    this.repair,
    this.error,
  });

  final bool busy;

  /// The last completed run, or null if none has been asked for yet.
  final AgentDiscoveryReport? report;

  /// What that run established about the stored executables — including the
  /// rows it could not put right, which are the ones only the user can fix.
  final AgentPathRepairReport? repair;

  /// Why the run could not be completed at all. Distinct from a run that
  /// completed and found nothing, which is a [report] with a zero count.
  final String? error;

  /// The sentence to show. Never a bare "done": a run that found nothing says
  /// so, and one that could not reach an environment names it.
  String? get message => error ?? report?.summary;
}

/// Runs agent detection again, on demand. Separate from
/// [AgentInstallationsController] because this holds the *view's* state.
class AgentRedetectController extends Notifier<AgentRedetectState> {
  @override
  AgentRedetectState build() => const AgentRedetectState();

  /// Re-probes everything and repairs a rotted path on the way, publishing the
  /// reading where the startup check publishes it so the two cannot disagree.
  Future<void> redetect() async {
    if (state.busy) return;
    state = const AgentRedetectState(busy: true);
    try {
      final repair = await ref
          .read(agentInstallationsControllerProvider.notifier)
          .repairBrokenPaths(full: true);
      // Published where the startup check publishes it, so both surfaces show
      // one reading rather than keeping two that can disagree.
      ref.read(agentPathRepairProvider.notifier).set(repair);
      state = AgentRedetectState(report: repair.scan, repair: repair);
    } on Object catch (e) {
      state = AgentRedetectState(error: 'Detection failed: $e');
    }
  }
}

final agentRedetectControllerProvider =
    NotifierProvider<AgentRedetectController, AgentRedetectState>(
      AgentRedetectController.new,
    );
