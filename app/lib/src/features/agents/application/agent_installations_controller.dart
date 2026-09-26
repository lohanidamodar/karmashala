import 'package:agent_cli/discovery.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused;
import 'package:riverpod/riverpod.dart';

import '../data/agents_data.dart';

/// Holds the known agent installations — the server's, followed as they
/// change. The server finds them, in every environment it can run a command
/// in (an SSH box's through this app), and keeps their rows true; this asks.
class AgentInstallationsController extends Notifier<List<AgentInstallation>> {
  AgentInstallationsData get _data => ref.read(agentInstallationsDataProvider);

  @override
  List<AgentInstallation> build() {
    final data = ref.watch(agentInstallationsDataProvider);
    final installations = data.getAll();
    final listening = data.changes.listen((_) => state = data.getAll());
    ref.onDispose(listening.cancel);
    return installations;
  }

  /// Asks the server to re-probe and reconcile every environment — the
  /// recovery path; an unreachable one reconciles against nothing.
  Future<AgentDiscoveryReport> discoverAll() =>
      ref.read(agentWorkProvider).detect();

  /// Asks the server to check the recorded executables and repair the rows
  /// whose path rotted; [full] re-probes everything on the way.
  Future<AgentPathRepairReport> repairBrokenPaths({bool full = false}) =>
      ref.read(agentWorkProvider).repair(full: full);

  /// Points one installation at [path] and records that a human chose it, so a
  /// sweep will not move it. False when another row already holds [path].
  Future<bool> setExecutablePath(String installationId, String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return false;
    try {
      await _data.setPath(installationId, trimmed);
    } on DataRefused {
      return false;
    }
    state = _data.getAll();
    return true;
  }
}

final agentInstallationsControllerProvider =
    NotifierProvider<AgentInstallationsController, List<AgentInstallation>>(
      AgentInstallationsController.new,
    );

/// The default installation from [installs]: [defaultInstallationId] if still
/// present, else the first of [defaultAgentId], else `null`.
AgentInstallation? resolveDefaultInstallation(
  List<AgentInstallation> installs, {
  String? defaultInstallationId,
  String? defaultAgentId,
}) {
  if (defaultInstallationId != null) {
    for (final install in installs) {
      if (install.id == defaultInstallationId) return install;
    }
  }
  if (defaultAgentId != null) {
    for (final install in installs) {
      if (install.agentId == defaultAgentId) return install;
    }
  }
  return null;
}
