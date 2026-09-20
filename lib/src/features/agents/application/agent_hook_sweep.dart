import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_core/logging.dart';

import 'agent_hook_installation_service.dart';
import 'agent_hook_intake.dart';

/// **Installs the hook that posts to [endpoint] into every agent that takes
/// one**, and publishes what happened.
///
/// One copy, called by the launch and by a control-server restart. The token
/// is inside [endpoint], so a restart that swept differently from the launch
/// would leave some agents posting to an address that no longer answers.
///
/// Never throws: the agents' config files are somebody else's, and a workspace
/// with no hooks still works — it just cannot report the hook-only states.
Future<AgentHookInstallationReport?> sweepAgentHooks(
  ProviderContainer container,
  AgentHookEndpoint endpoint, {
  AppLogger? logger,
}) async {
  try {
    final results = await container
        .read(agentHookInstallationServiceProvider)
        .installAll(endpoint);
    final report = AgentHookInstallationReport(results);
    // Published, not just logged: a skipped environment means the hook-only
    // states are unreportable there all run, and Settings is where to say so.
    container.read(agentHookInstallationReportProvider.notifier).set(report);
    // The environments that report by file rather than by socket — a WSL agent
    // cannot reach any address this app binds. An empty list stops the timer.
    container.read(agentHookSpoolDrainerProvider).watch(report.spoolSources);
    logger?.info(
      'Agent hooks: ${report.installed} installed, '
      '${results.length - report.installed - report.unknown} skipped'
      '${report.unknown == 0 ? '' : ', ${report.unknown} unknown'}'
      '${report.spoolSources.isEmpty ? '' : ', '
                '${report.spoolSources.length} reporting by spool'}.',
    );
    return report;
  } on Object catch (error, stack) {
    logger?.warning('Agent hook installation failed.', error, stack);
    return null;
  }
}
