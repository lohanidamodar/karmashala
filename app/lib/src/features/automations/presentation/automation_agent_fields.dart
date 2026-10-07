import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:flutter/material.dart';

/// Which installed agent runs it — or why there is none to pick.
class AutomationAgentField extends StatelessWidget {
  const AutomationAgentField({
    required this.installations,
    required this.selectedId,
    required this.displayNameFor,
    required this.onChanged,
    super.key,
  });

  final List<AgentInstallation> installations;
  final String? selectedId;
  final String Function(String agentId) displayNameFor;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (installations.isEmpty) {
      return Text(
        'No agent is installed in this checkout\'s environment, so '
        'there is nothing here to start.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }
    return DropdownButtonFormField<String>(
      initialValue: selectedId,
      decoration: const InputDecoration(labelText: 'Agent'),
      items: [
        for (final installation in installations)
          DropdownMenuItem(
            value: installation.id,
            child: Text(displayNameFor(installation.agentId)),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

/// The agent's own modes, flat and safest first. Whole selections rather than
/// a picker per axis, because the gate reads the whole selection's rung.
class AutomationPermissionModeField extends StatelessWidget {
  const AutomationPermissionModeField({
    required this.agentName,
    required this.support,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final String agentName;

  /// Null, or not known, when the modes of this agent were never established.
  final AgentPermissionSupport? support;
  final PermissionSelection? value;
  final ValueChanged<PermissionSelection?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final support = this.support;
    if (support == null || !support.isKnown) {
      return Text(
        unknownAgentReason(agentName),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }
    final selections = support.selections();
    final resolved = support.normalise(value).canonical;
    return DropdownButtonFormField<String>(
      initialValue: selections.any((s) => s.canonical == resolved)
          ? resolved
          : null,
      decoration: const InputDecoration(
        labelText: 'Permission mode',
        helperText:
            'A mode that stops to ask cannot run unattended: nobody would be '
            'there to answer.',
      ),
      items: [
        for (final selection in selections)
          DropdownMenuItem(
            value: selection.canonical,
            // Whole selections rather than axes, so the familiar name is the
            // composed rung's — the one the unattended gate reads.
            child: Text(describeSelectionFamiliar(support, selection)),
          ),
      ],
      onChanged: (value) =>
          onChanged(value == null ? null : PermissionSelection.parse(value)),
    );
  }
}
