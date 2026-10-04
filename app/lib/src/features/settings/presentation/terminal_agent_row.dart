import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/presentation/agent_logo.dart';
import '../../agents/presentation/agent_version_label.dart';
import 'agent_collapsed_row.dart';
import 'agent_health.dart';
import 'agent_label.dart';

/// The sentence for an agent found on no machine, naming the binary to put
/// there. With npx, when the agent can run from its package instead.
String notInstalledLine(AgentDescriptor descriptor) {
  final binary = [
    ...descriptor.binaries.posix,
    ...descriptor.binaries.windows,
  ].firstOrNull;
  final install = binary == null ? 'Install it' : 'Install `$binary`';
  final npx = descriptor.acp?.npxPackage == null ? '' : ', or add it with npx';
  return 'Not installed. $install on a machine Karmashala reaches$npx.';
}

/// **A terminal agent, folded** (Claude Code, Codex, Antigravity): its
/// health, where it is installed, and the newest version read — flagged in
/// words as well as colour when a machine is behind. Its machines include
/// those its chat form is installed on ([chatInstalls]), said on a line of
/// its own.
class TerminalAgentRow extends ConsumerWidget {
  const TerminalAgentRow({
    required this.descriptor,
    required this.installs,
    this.chatInstalls = const [],
    this.trailing,
    super.key,
  });

  final AgentDescriptor descriptor;
  final List<AgentInstallation> installs;
  final List<AgentInstallation> chatInstalls;
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = [...installs, ...chatInstalls];
    final health = readAgentHealth(ref, installs: all);
    final terminal = installs.isEmpty
        ? Text(notInstalledLine(descriptor))
        : _VersionLine(installs: installs);
    return AgentCollapsedRow(
      name: agentLabel(ref, descriptor.id),
      logo: AgentLogo(agentId: descriptor.id, size: Chrome.iconAction),
      health: health,
      environmentIds: {for (final i in all) i.environmentId},
      detail: chatInstalls.isEmpty
          ? terminal
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                terminal,
                Text(
                  'Chat: ${describeAgentVersions(chatInstalls, now: ref.watch(clockProvider).nowUtc())}',
                ),
              ],
            ),
      trailing: trailing,
    );
  }
}

/// The newest version read across the machines, with its age, and the
/// release a machine should move to when one is behind.
class _VersionLine extends ConsumerWidget {
  const _VersionLine({required this.installs});

  final List<AgentInstallation> installs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).nowUtc();
    final version = describeAgentVersions(installs, now: now);
    String? updateTo;
    for (final install in installs) {
      updateTo ??= agentInstallUpdateTarget(ref, install, installs);
    }
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: version),
          if (updateTo != null)
            TextSpan(
              text: ' · update to $updateTo',
              style: TextStyle(color: SemanticColors.of(context).attention),
            ),
        ],
      ),
    );
  }
}
