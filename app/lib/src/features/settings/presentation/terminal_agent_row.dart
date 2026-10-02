import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
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
/// words as well as colour when a machine is behind.
class TerminalAgentRow extends ConsumerWidget {
  const TerminalAgentRow({
    required this.descriptor,
    required this.installs,
    this.trailing,
    super.key,
  });

  final AgentDescriptor descriptor;
  final List<AgentInstallation> installs;
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = readAgentHealth(ref, installs: installs);
    return AgentCollapsedRow(
      name: agentLabel(ref, descriptor.id),
      health: health,
      environmentIds: installs.map((i) => i.environmentId),
      detail: installs.isEmpty
          ? Text(notInstalledLine(descriptor))
          : _VersionLine(installs: installs),
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
    final newest = newestAgentVersion(installs);
    final shown =
        installs.where((i) => i.version == newest).firstOrNull ??
        installs.firstWhere(
          (i) => i.version != null,
          orElse: () => installs.first,
        );
    final version = describeVersionReading(shown, now: now);
    String? updateTo;
    for (final install in installs) {
      updateTo ??= agentInstallUpdateTarget(ref, install, installs);
    }
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: version ?? 'version not read'),
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
