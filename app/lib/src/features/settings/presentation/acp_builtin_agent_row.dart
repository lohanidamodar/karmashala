import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/presentation/agent_logo.dart';
import '../../agents/presentation/agent_version_label.dart';
import '../../environments/application/environments_controller.dart';
import 'acp_install_actions.dart';
import 'acp_login_lines.dart';
import 'agent_collapsed_row.dart';
import 'agent_health.dart';
import 'agent_label.dart';
import 'terminal_agent_row.dart' show notInstalledLine;

/// What every ACP agent has in common, said once per group and on hover: no
/// terminal, no usage here, a login by method rather than account, and the
/// agent's own default mode.
const acpAgentsNote =
    'These agents run as chat sessions over the Agent Client Protocol. They '
    'keep no usage here, log in by a method the agent offers, and start '
    'under their own default mode.';

/// How one install is started: `npx -y <package>` when discovery fell back
/// to the package runner, else the binary's path.
String describeAgentLaunch(AgentInstallation install) =>
    install.leadingArguments.isEmpty
    ? install.executable.path
    : 'npx ${install.leadingArguments.join(' ')}';

/// **A shipped ACP agent, one row** (Grok, or a chat form whose agent this
/// registry lacks): its health, where it is installed, how each machine
/// launches it, the version the agent reported of itself over ACP, and each
/// installation's login ([AcpLoginLine]). No account or permission block —
/// none applies to an agent driven over ACP — one line saying so when it is
/// installed nowhere, and an install action per machine for an agent the
/// registry ships as an archive.
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
    final name = agentLabel(ref, descriptor.id);
    return AgentCollapsedRow(
      name: name,
      logo: AgentLogo(agentId: descriptor.id, size: Chrome.iconAction),
      health: health,
      environmentIds: installs.map((i) => i.environmentId),
      tooltip: acpAgentsNote,
      detail: AcpAgentDetails(descriptor: descriptor, installs: installs),
    );
  }
}

/// How an ACP agent — or an agent's chat form — launches on each machine,
/// the version it reported, each installation's login, and an install
/// action per machine it is not on.
class AcpAgentDetails extends ConsumerWidget {
  const AcpAgentDetails({
    required this.descriptor,
    required this.installs,
    super.key,
  });

  final AgentDescriptor descriptor;
  final List<AgentInstallation> installs;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (installs.isEmpty)
        Text(notInstalledLine(descriptor))
      else ...[
        AgentLaunchLines(installs: installs),
        Text(
          describeAgentVersions(
            installs,
            now: ref.watch(clockProvider).nowUtc(),
          ),
        ),
        AcpLoginLines(
          installs: installs,
          agentName: agentLabel(ref, descriptor.id),
        ),
      ],
      AcpInstallActions(
        descriptor: descriptor,
        installedOn: {for (final install in installs) install.environmentId},
      ),
    ],
  );
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
