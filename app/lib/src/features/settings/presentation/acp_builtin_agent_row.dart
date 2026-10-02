import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../environments/application/environments_controller.dart';
import 'agent_collapsed_row.dart';
import 'agent_health.dart';
import 'agent_label.dart';
import 'terminal_agent_row.dart' show notInstalledLine;

/// What every ACP agent has in common, said once per group and on hover: no
/// terminal, no account or usage here, and the agent's own default mode.
const acpAgentsNote =
    'These agents run as chat sessions over the Agent Client Protocol. They '
    'keep no account or usage here and start under their own default mode.';

/// How one install is started: `npx -y <package>` when discovery fell back
/// to the package runner, else the binary's path.
String describeAgentLaunch(AgentInstallation install) =>
    install.leadingArguments.isEmpty
    ? install.executable.path
    : 'npx ${install.leadingArguments.join(' ')}';

/// **A shipped ACP agent, one row** (Claude (ACP), Codex (ACP), Gemini CLI,
/// Grok): its health, where it is installed, and how each machine launches
/// it. No version, account or permission block — none applies to an agent
/// driven over ACP — and one line saying so when it is installed nowhere.
class AcpBuiltInAgentRow extends ConsumerWidget {
  const AcpBuiltInAgentRow({
    required this.descriptor,
    required this.installs,
    super.key,
  });

  final AgentDescriptor descriptor;
  final List<AgentInstallation> installs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = readAgentHealth(ref, installs: installs);
    return AgentCollapsedRow(
      name: agentLabel(ref, descriptor.id),
      health: health,
      environmentIds: installs.map((i) => i.environmentId),
      tooltip: acpAgentsNote,
      detail: installs.isEmpty
          ? Text(notInstalledLine(descriptor))
          : AgentLaunchLines(installs: installs),
    );
  }
}

/// One launch per machine, in the ledger hand; the machine is named only when
/// there is more than one.
class AgentLaunchLines extends ConsumerWidget {
  const AgentLaunchLines({required this.installs, super.key});

  final List<AgentInstallation> installs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = MonoStyles.small.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final install in installs)
          Text(
            installs.length == 1
                ? describeAgentLaunch(install)
                : '${ref.watch(environmentLabelForIdProvider(install.environmentId))}: '
                      '${describeAgentLaunch(install)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
      ],
    );
  }
}
