import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/agent_discovery_report.dart';
import 'agent_installations_controller.dart';

/// What the last re-detection did, for the control that started it.
class AgentRedetectState {
  const AgentRedetectState({this.busy = false, this.report, this.error});

  final bool busy;

  /// The last completed run, or null if none has been asked for yet.
  final AgentDiscoveryReport? report;

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

  Future<void> redetect() async {
    if (state.busy) return;
    state = const AgentRedetectState(busy: true);
    try {
      final report = await ref
          .read(agentInstallationsControllerProvider.notifier)
          .discoverAll();
      state = AgentRedetectState(report: report);
    } on Object catch (e) {
      state = AgentRedetectState(error: 'Detection failed: $e');
    }
  }
}

final agentRedetectControllerProvider =
    NotifierProvider<AgentRedetectController, AgentRedetectState>(
      AgentRedetectController.new,
    );
