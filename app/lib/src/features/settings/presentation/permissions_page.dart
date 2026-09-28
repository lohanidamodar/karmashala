import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
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
/// and existing sessions, one flat row per agent, purpose and axis — the
/// board's rows, not a card per agent.
class PermissionModesSection extends ConsumerWidget {
  const PermissionModesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    return SettingsSection(
      title: SettingsAnchor.permissionModes.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Which way precedence runs: a session that chose keeps its own.
          const SettingsNote(
            'Defaults only: a mode picked on a session keeps it.',
          ),
          for (final descriptor in AgentRegistry.builtIn.descriptors)
            _PermissionRows(
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

class _PermissionRows extends StatelessWidget {
  const _PermissionRows({
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
    final name = descriptor.displayName;
    final support = descriptor.launch.permission;
    final newSelection = support.resolveStored(permissions.newSessions);
    final existingSelection = support.resolveStored(
      permissions.existingSessions,
    );
    final dangerous =
        support.isDangerous(newSelection) ||
        support.isDangerous(existingSelection);
    // An agent whose modes are unestablished offers no dropdowns.
    if (!support.isKnown) {
      return SettingsNote(
        name,
        child: SettingsNotice(
          tone: SettingsNoticeTone.danger,
          message: unknownAgentReason(name),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // One row per axis per purpose: Codex's four do not fit one row.
        for (final (purpose, selection, onChanged) in [
          ('new sessions', newSelection, onNew),
          ('existing sessions', existingSelection, onExisting),
        ])
          for (final axis in permissionAxisOptionsFor(
            descriptor,
            selection: selection,
          ))
            SettingsRow(
              label: '$name · $purpose',
              help: axis.label,
              controlMaxWidth: 260,
              control: PermissionAxisDropdown(
                axis: axis,
                selection: selection,
                support: support,
                labelled: false,
                onChanged: onChanged,
              ),
            ),
        if (dangerous)
          SettingsNote(
            '$name can act with nothing in the way.',
            child: SettingsNotice(
              tone: SettingsNoticeTone.danger,
              icon: AppIcons.warning,
              message:
                  'This default lets $name act with nothing in the way. Use '
                  'it only in trusted repositories.',
            ),
          ),
      ],
    );
  }
}

/// One permission axis of one purpose as a dropdown, writing back the whole
/// selection so the other axis is not silently reset. Shared by Tools and
/// reach and each agent's behaviour on Agents and accounts, so the two cannot
/// offer different modes.
class PermissionAxisDropdown extends StatelessWidget {
  const PermissionAxisDropdown({
    required this.axis,
    required this.selection,
    required this.support,
    required this.onChanged,
    this.labelled = true,
    super.key,
  });

  final AgentPermissionAxisOptions axis;
  final PermissionSelection selection;
  final AgentPermissionSupport support;
  final ValueChanged<String> onChanged;

  /// Whether the field carries the axis's name itself; off on a settings row,
  /// whose label already says it.
  final bool labelled;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: axis.selectedId,
      isExpanded: true,
      decoration: InputDecoration(labelText: labelled ? axis.label : null),
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
    final projects = ref.watch(projectsControllerProvider);
    final store = ref.watch(browserConsentStoreProvider);
    // The store reads storage per call, so there is nothing to watch.
    ref.watch(browserConsentRevisionProvider);

    return SettingsSection(
      title: SettingsAnchor.browser.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SettingsNote(
            'browser_evaluate runs agent JavaScript that can read your '
            'cookies and tokens. Off until allowed, per project.',
          ),
          if (projects.isEmpty)
            const SettingsNote(
              'No projects yet. Add one and it will be listed here.',
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
