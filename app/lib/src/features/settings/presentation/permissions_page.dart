import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_browser/browser.dart';

import '../../browser/application/browser_consent_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../application/settings_controller.dart';
import '../domain/settings.dart';
import 'settings_catalog.dart';
import 'settings_row.dart';
import 'settings_section.dart';
import 'settings_notice.dart';

/// Settings → Tools and reach → Permission modes: per-agent defaults for new
/// and existing sessions.
class PermissionModesSection extends ConsumerWidget {
  const PermissionModesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    return SettingsSection(
      title: SettingsAnchor.permissionModes.heading,
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
    final existingSelection = support.resolveStored(
      permissions.existingSessions,
    );
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
                    // At most 260, not exactly: a split pane narrower than
                    // that would overflow a fixed width.
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 260),
                      child: _axisDropdown(axis, selection, support, onChanged),
                    ),
                ],
              ),
              const SizedBox(height: Insets.sm),
            ],
          ],
          const SizedBox(height: Insets.xs),
          // Which way precedence runs: a session that chose keeps its own.
          Text(
            'Defaults only: a mode picked on a session keeps it.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (dangerous)
            Padding(
              padding: const EdgeInsets.only(top: Insets.sm),
              child: SettingsNotice(
                tone: SettingsNoticeTone.danger,
                icon: AppIcons.warning,
                message:
                    'This default lets ${descriptor.displayName} act with '
                    'nothing in the way. Use it only in trusted '
                    'repositories.',
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

/// Settings → Tools and reach → Browser: a per-project consent switch rather
/// than a prompt on first `browser_evaluate` — the agent may run with nobody
/// there.
class BrowserConsentSection extends ConsumerWidget {
  const BrowserConsentSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final projects = ref.watch(projectsControllerProvider);
    final store = ref.watch(browserConsentStoreProvider);
    // The store reads storage per call, so there is nothing to watch.
    ref.watch(browserConsentRevisionProvider);

    return SettingsSection(
      title: SettingsAnchor.browser.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm),
            child: Text(
              'browser_evaluate runs agent JavaScript that can read your '
              'cookies and tokens. Off until allowed, per project.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (projects.isEmpty)
            Text(
              'No projects yet. Add one and it will be listed here.',
              style: theme.textTheme.bodySmall,
            )
          else
            for (final project in projects)
              Builder(
                builder: (context) {
                  final grant = store.grantFor(
                    project.id,
                    BrowserCapability.evaluate,
                  );
                  return SettingsSwitchRow(
                    label: 'Run JavaScript in the page — ${project.name}',
                    // The date is why a grant is a record, not a boolean.
                    help: grant == null
                        ? 'Not allowed. Agents working in this project cannot '
                              'call browser_evaluate.'
                        : 'Allowed since '
                              '${grant.grantedAt.toLocal()} '
                              '(${grant.grantedBy}).',
                    value: grant != null,
                    onChanged: (allow) {
                      if (allow) {
                        store.grant(
                          project.id,
                          BrowserCapability.evaluate,
                          grantedBy: kBrowserConsentLocation,
                        );
                      } else {
                        store.revoke(project.id, BrowserCapability.evaluate);
                      }
                      ref.read(browserConsentRevisionProvider.notifier).bump();
                    },
                  );
                },
              ),
        ],
      ),
    );
  }
}
