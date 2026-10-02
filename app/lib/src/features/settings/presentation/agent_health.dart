import 'package:agent_cli/discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../agents/application/agent_latest_versions_controller.dart';
import '../../agents/application/agent_path_repair_providers.dart';
import '../../agents/presentation/agent_version_label.dart';
import '../../environments/application/environments_controller.dart';

export '../../agents/presentation/agent_version_label.dart'
    show newestAgentVersion;

/// One glyph's worth of an agent's state on the collapsed row.
enum AgentHealth { installed, notInstalled, attention }

/// The glyph and the sentence behind it, read together so the words and the
/// colour cannot disagree.
class AgentHealthReading {
  const AgentHealthReading(this.health, this.summary);

  final AgentHealth health;

  /// What the glyph means, for the tooltip and the screen reader.
  final String summary;
}

/// The version [install] should move to, or null when it is current.
String? agentInstallUpdateTarget(
  WidgetRef ref,
  AgentInstallation install,
  List<AgentInstallation> siblings,
) => agentUpdateTarget(
  install,
  latest: ref.watch(agentLatestVersionsProvider).latestOf(install.agentId),
  newestOnMachines: newestAgentVersion(siblings),
);

/// Reads one agent's health off what the page already knows: where it is
/// installed, whether a stored path failed to open, and whether a machine is
/// behind a release.
AgentHealthReading readAgentHealth(
  WidgetRef ref, {
  required List<AgentInstallation> installs,
}) {
  if (installs.isEmpty) {
    return const AgentHealthReading(
      AgentHealth.notInstalled,
      'Not installed on any machine',
    );
  }
  final repair = ref.watch(agentPathRepairProvider);
  for (final reading in repair.unresolved) {
    if (!installs.any((i) => i.id == reading.installation.id)) continue;
    final where = ref.watch(
      environmentLabelForIdProvider(reading.installation.environmentId),
    );
    return AgentHealthReading(
      AgentHealth.attention,
      switch (reading.reachability) {
        ExecutableReachability.unreachable =>
          'The path on $where cannot be reached',
        _ => 'Nothing opens at the path on $where',
      },
    );
  }
  for (final install in installs) {
    final target = agentInstallUpdateTarget(ref, install, installs);
    if (target != null) {
      return AgentHealthReading(AgentHealth.attention, 'Update to $target');
    }
  }
  final count = installs.map((i) => i.environmentId).toSet().length;
  return AgentHealthReading(
    AgentHealth.installed,
    'Installed on $count machine${count == 1 ? '' : 's'}',
  );
}

/// The one-glyph health at the head of an agent's row. Never colour alone:
/// the reading's sentence is its tooltip and its semantics.
class AgentHealthGlyph extends StatelessWidget {
  const AgentHealthGlyph({required this.reading, super.key});

  final AgentHealthReading reading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = SemanticColors.of(context);
    final (icon, color) = switch (reading.health) {
      AgentHealth.installed => (AppIcons.checkCircle, scheme.primary),
      AgentHealth.notInstalled => (AppIcons.circle, scheme.outline),
      AgentHealth.attention => (AppIcons.warningCircle, semantic.attention),
    };
    return Tooltip(
      message: reading.summary,
      child: Semantics(
        label: reading.summary,
        child: Icon(icon, size: Chrome.icon, color: color),
      ),
    );
  }
}
