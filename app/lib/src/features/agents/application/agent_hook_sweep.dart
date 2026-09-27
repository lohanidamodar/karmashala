import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_core/logging.dart';

import '../../../core/probe/probe_mode.dart';
import 'agent_hook_installation_service.dart';
import 'host_hook_endpoint.dart';

/// Sweeps run one at a time: two at once would splice the same agent configs.
class _AgentHookSweeps {
  Future<void> tail = Future<void>.value();
  AgentHookEndpoint? last;
}

final _agentHookSweepsProvider = Provider<_AgentHookSweeps>(
  (ref) => _AgentHookSweeps(),
);

/// **Installs the hook that posts to [endpoint] into every agent that takes
/// one**, and publishes what happened.
///
/// One copy, called by the launch, a control-server restart and a session host
/// that came up. The token is inside [endpoint], so a sweep that differed
/// would leave some agents posting to an address that no longer answers.
/// [unlessCurrent] skips a sweep of the endpoint the last one installed.
///
/// Never throws: the agents' config files are somebody else's, and a workspace
/// with no hooks still works — it just cannot report the hook-only states.
Future<AgentHookInstallationReport?> sweepAgentHooks(
  ProviderContainer container,
  AgentHookEndpoint endpoint, {
  AppLogger? logger,
  bool unlessCurrent = false,
}) {
  final sweeps = container.read(_agentHookSweepsProvider);
  final result = sweeps.tail.then((_) async {
    if (unlessCurrent && (sweeps.last?.sameAs(endpoint) ?? false)) return null;
    final report = await _sweep(container, endpoint, logger);
    if (report != null) sweeps.last = endpoint;
    return report;
  });
  sweeps.tail = result.then((_) {});
  return result;
}

/// Points local agents' hooks at the session host's endpoint when it is not
/// what they were last given — a host that just came up, or one restarted on
/// another port. Nothing when hooks are the app's, or in a probe.
Future<void> sweepHostHooks(ProviderContainer container, {AppLogger? logger}) {
  if (container.read(probeModeProvider).enabled) return Future<void>.value();
  if (!container.read(agentHooksAtHostProvider)) return Future<void>.value();
  final endpoint = hostHookEndpoint(container);
  if (endpoint == null) return Future<void>.value();
  return sweepAgentHooks(
    container,
    endpoint,
    logger: logger,
    unlessCurrent: true,
  );
}

Future<AgentHookInstallationReport?> _sweep(
  ProviderContainer container,
  AgentHookEndpoint endpoint,
  AppLogger? logger,
) async {
  try {
    final results = await container
        .read(agentHookInstallationServiceProvider)
        .installAll(endpoint);
    final report = AgentHookInstallationReport(results);
    // Published, not just logged: a skipped environment means the hook-only
    // states are unreportable there all run, and Settings is where to say so.
    container.read(agentHookInstallationReportProvider.notifier).set(report);
    logger?.info(
      'Agent hooks: ${report.installed} installed, '
      '${results.length - report.installed - report.unknown} skipped'
      '${report.unknown == 0 ? '' : ', ${report.unknown} unknown'}.',
    );
    return report;
  } on Object catch (error, stack) {
    logger?.warning('Agent hook installation failed.', error, stack);
    return null;
  }
}
