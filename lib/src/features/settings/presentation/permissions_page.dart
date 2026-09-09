import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../agents/domain/agent_descriptor.dart';
import '../../agents/domain/agent_permission_options.dart';
import '../../agents/domain/agent_permission_support.dart';
import '../../agents/domain/agent_registry.dart';
import '../application/settings_controller.dart';
import '../domain/settings.dart';
import 'settings_section.dart';

/// Settings → Permissions: per-agent permission preferences for new and
/// existing sessions.
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
    return Card(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      child: Padding(
        padding: const EdgeInsets.all(Insets.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(descriptor.displayName, style: theme.textTheme.titleSmall),
            const SizedBox(height: Insets.sm),
            if (!support.isKnown)
              // The disabled-with-a-reason rule, at the one place a default is
              // set: an agent whose modes nobody has established offers no
              // dropdowns rather than three that would do nothing.
              Text(
                unknownAgentReason(descriptor.displayName),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              )
            else ...[
              // One picker per axis per purpose. Codex has two axes, so its
              // card draws four controls — which is why this wraps instead of
              // sitting in a Row: four dropdowns across do not fit the 720px
              // minimum window, let alone at 1.3x text.
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
            // Says which way the precedence runs, because the natural reading
            // of a settings screen is the opposite one: these are the modes a
            // session starts under **until it chooses**, and a session that has
            // chosen keeps its own when this changes.
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
      ),
    );
  }

  /// One axis of one purpose. Writing back the **whole** selection rather than
  /// the changed axis keeps the other axis where the user left it — a sandbox
  /// picked here must not silently reset the approval policy beside it.
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
            // Per row rather than per selection: this page picks one axis at a
            // time, and the row's own rung is what its name should say.
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
