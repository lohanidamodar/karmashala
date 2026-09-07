import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/agent_discovery_report.dart';
import '../domain/agent_path_repair.dart';
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

/// Runs agent detection again, on demand.
///
/// Separate from [AgentInstallationsController] because this holds the *view's*
/// state — busy, and the account of the last run — which the installation list
/// itself has no business carrying.
class AgentRedetectController extends Notifier<AgentRedetectState> {
  @override
  AgentRedetectState build() => const AgentRedetectState();

  /// Re-probes everything, and repairs a rotted path on the way.
  ///
  /// The repair is not a separate step here: `discoverAll` is the same
  /// reconciling sweep the startup check narrows, so it already resolves a
  /// junction chain, follows a moved executable *keeping its row id*, and keeps
  /// a row it could not reach rather than deleting it. What this adds is the
  /// **reading** — the filesystem asked again afterwards, published where the
  /// startup check publishes it, so a user who presses this button sees the
  /// same account of what is reachable that a launch would have given them.
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
