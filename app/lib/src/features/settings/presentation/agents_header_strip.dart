import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/agent_redetect_controller.dart';
import 'agents_pages.dart' show DefaultAgentRow;
import 'settings_catalog.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// **The strip over the groups** (board "Defaults"): how many agents the app
/// knows, how many are installed and on how many machines, the one button
/// that looks for them again, and the agent a new session starts on.
class AgentsHeaderStrip extends ConsumerWidget {
  const AgentsHeaderStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final redetect = ref.watch(agentRedetectControllerProvider);
    return SettingsSection(
      title: SettingsAnchor.defaultAgent.heading,
      trailing: TextButton.icon(
        onPressed: redetect.busy
            ? null
            : () =>
                  ref.read(agentRedetectControllerProvider.notifier).redetect(),
        icon: redetect.busy
            ? const InlineSpinner()
            : const Icon(AppIcons.arrowsClockwise),
        label: Text(redetect.busy ? 'Discovering…' : 'Discover agents'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AgentsSummaryRow(),
          if (redetect.error case final error?)
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.sm),
              child: DesktopErrorBanner(error),
            ),
          const DefaultAgentRow(),
        ],
      ),
    );
  }
}

/// "7 agents · 3 installed on 2 machines", with what the last scan said
/// under it — or that none has run yet this session.
class AgentsSummaryRow extends ConsumerWidget {
  const AgentsSummaryRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agents = ref.watch(agentRegistryProvider).descriptors.length;
    final installations = ref.watch(agentInstallationsControllerProvider);
    final installed = installations.map((i) => i.agentId).toSet().length;
    final machines = installations.map((i) => i.environmentId).toSet().length;
    final report = ref.watch(agentRedetectControllerProvider).report;
    return SettingsRow(
      label:
          '${_count(agents, 'agent')} · $installed installed on '
          '${_count(machines, 'machine')}',
      help:
          report?.summary ??
          'Discover looks on every machine for agents installed since. Not '
              'scanned yet in this session.',
      control: const SizedBox.shrink(),
    );
  }

  static String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
}
