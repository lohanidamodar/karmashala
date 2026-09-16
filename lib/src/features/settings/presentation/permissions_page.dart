import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:agent_cli/descriptors.dart';
import '../application/settings_controller.dart';
import '../domain/settings.dart';
import 'settings_section.dart';

/// Settings → Permissions: per-agent preferences for new and existing sessions.
class PermissionsPage extends ConsumerWidget {
  const PermissionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    return SettingsSection(
      title: 'PERMISSIONS',
      child: Column(
        children: [
          for (final descriptor in AgentRegistry.builtIn.descriptors)
            _PermissionCard(
              descriptor: descriptor,
              permissions: settings.permissionsFor(descriptor.id),
              onNew: (m) =>
                  controller.setNewSessionPermission(descriptor.id, m),
              onExisting: (m) =>
                  controller.setExistingSessionPermission(descriptor.id, m),
            ),
        ],
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.descriptor,
    required this.permissions,
    required this.onNew,
    required this.onExisting,
  });

  final AgentDescriptor descriptor;
  final AgentPermissions permissions;
  final ValueChanged<String> onNew;
  final ValueChanged<String> onExisting;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final support = descriptor.launch.permission;
    final newSelection = support.resolveStored(permissions.newSessions);
    final existingSelection = support.resolveStored(permissions.existingSessions);
    final dangerous =
        support.isDangerous(newSelection) ||
        support.isDangerous(existingSelection);
    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(descriptor.displayName, style: theme.textTheme.titleSmall),
          const SizedBox(height: Insets.sm),
          if (!support.isKnown)
            // An agent whose modes are unestablished offers no dropdowns.
            Text(
              unknownAgentReason(descriptor.displayName),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            )
          else ...[
            // One picker per axis per purpose: Codex's four do not fit a Row.
            for (final (label, selection, onChanged) in [
              ('New sessions', newSelection, onNew),
              ('Existing sessions', existingSelection, onExisting),
            ]) ...[
              Text(label, style: theme.textTheme.labelSmall),
              const SizedBox(height: Insets.xs),
              Wrap(
                spacing: Insets.md,
                runSpacing: Insets.sm,
                children: [
                  for (final axis in permissionAxisOptionsFor(
                    descriptor,
                    selection: selection,
                  ))
                    SizedBox(
                      width: 260,
                      child: _axisDropdown(
                        axis,
                        selection,
                        support,
                        onChanged,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: Insets.sm),
            ],
          ],
          const SizedBox(height: Insets.xs),
          // Which way precedence runs: a session that chose keeps its own.
          Text(
            'Defaults for sessions that have not chosen a mode of their own. '
            'A mode picked on a session keeps that session, even after this '
            'changes.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (dangerous)
            Padding(
              padding: const EdgeInsets.only(top: Insets.sm),
              child: Row(
                children: [
                  Icon(
                    AppIcons.warning,
                    size: Chrome.icon,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: Insets.xs),
                  Expanded(
                    child: Text(
                      'This default lets ${descriptor.displayName} act with '
                      'nothing in the way. Use it only in trusted '
                      'repositories.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// One axis of one purpose, writing back the whole selection so the other
  /// axis is not silently reset.
  Widget _axisDropdown(
    AgentPermissionAxisOptions axis,
    PermissionSelection selection,
    AgentPermissionSupport support,
    ValueChanged<String> onChanged,
  ) {
    return DropdownButtonFormField<String>(
      initialValue: axis.selectedId,
      isExpanded: true,
      decoration: InputDecoration(labelText: axis.label),
      items: [
        for (final option in axis.options)
          DropdownMenuItem(
            value: option.id,
            enabled: option.isSelectable,
            // Per row, not per selection: this page picks one axis at a time.
            child: Text(option.pairedLabel, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (picked) {
        if (picked == null) return;
        onChanged(
          support
              .normalise(
                PermissionSelection({
                  ...support.normalise(selection).values,
                  axis.id: picked,
                }),
              )
              .canonical,
        );
      },
    );
  }
}
