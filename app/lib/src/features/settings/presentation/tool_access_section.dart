import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused;
import 'package:karmashala_mcp/catalogue.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../sessions/application/tool_access_providers.dart';
import 'settings_catalog.dart';
import 'settings_row.dart';
import 'settings_section.dart';
import 'settings_theme.dart';

/// Settings → Permissions → Tool access: which operator tool groups every
/// session may use without Operate Karmashala. Hidden on a server that does
/// not keep it, and on a phone that may not start sessions.
class ToolAccessSection extends ConsumerWidget {
  const ToolAccessSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(capabilitiesProvider.select((c) => c.toolAccess))) {
      return const SizedBox.shrink();
    }
    final policy =
        ref.watch(toolAccessProvider).value ?? McpToolAccessPolicy.defaults;
    void write(McpToolAccessPolicy next) => _write(context, ref, next);
    return SettingsSection(
      title: SettingsAnchor.toolAccess.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SettingsNote(
            'What a session may do to other sessions without Operate '
            'Karmashala. A project can override these on its Details page. '
            'This is not a sandbox.',
          ),
          for (final group in McpToolGroup.values) ...[
            SettingsRow(
              key: ValueKey('tool-access:${group.id}'),
              label: group.label,
              help: group.meaning,
              control: Switch(
                value: policy.groupOn(group),
                onChanged: (on) => write(
                  policy.withGlobal(
                    policy.global.withGroup(
                      group,
                      on == group.defaultOn ? null : on,
                    ),
                  ),
                ),
              ),
            ),
            if (group == McpToolGroup.message)
              SettingsRow(
                key: const ValueKey('tool-access:message-any-project'),
                label: 'Any project',
                help:
                    'Message sessions in every project, not only its own, '
                    'its parent and its children.',
                control: Switch(
                  value: policy.messageAnyProject,
                  onChanged: (any) => write(policy.withMessageAnyProject(any)),
                ),
              ),
            ToolAccessAdvanced(
              group: group,
              storageKey: 'tool-access:global:${group.id}',
              levelOf: policy.global.tool,
              unsetLabel: 'Default',
              onChanged: (tool, on) =>
                  write(policy.withGlobal(policy.global.withTool(tool, on))),
            ),
          ],
        ],
      ),
    );
  }
}

/// A project page's Tool access rows: each group, and each of its tools under
/// Advanced, as Inherit, On or Off for sessions in [projectId].
class ProjectToolAccessRows extends ConsumerWidget {
  const ProjectToolAccessRows({required this.projectId, super.key});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy =
        ref.watch(toolAccessProvider).value ?? McpToolAccessPolicy.defaults;
    final here = policy.project(projectId);
    void write(McpToolAccessOverrides next) =>
        _write(context, ref, policy.withProject(projectId, next));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final group in McpToolGroup.values) ...[
          SettingsRow(
            key: ValueKey('project-tool-access:${group.id}'),
            label: group.label,
            help:
                '${group.meaning} Inherited: '
                '${policy.groupOn(group) ? 'on' : 'off'}.',
            control: ToolAccessLevelPicker(
              key: ValueKey('project-tool-access-picker:${group.id}'),
              value: here.group(group),
              unsetLabel: 'Inherit',
              onChanged: (on) => write(here.withGroup(group, on)),
            ),
          ),
          ToolAccessAdvanced(
            group: group,
            storageKey: 'tool-access:$projectId:${group.id}',
            levelOf: here.tool,
            unsetLabel: 'Inherit',
            onChanged: (tool, on) => write(here.withTool(tool, on)),
          ),
        ],
      ],
    );
  }
}

/// A group's tools, folded: one three-state picker each.
class ToolAccessAdvanced extends StatelessWidget {
  const ToolAccessAdvanced({
    required this.group,
    required this.storageKey,
    required this.levelOf,
    required this.unsetLabel,
    required this.onChanged,
    super.key,
  });

  final McpToolGroup group;

  /// Its own PageStorage slot, so the fold is not read from a scroll offset.
  final String storageKey;
  final bool? Function(String tool) levelOf;
  final String unsetLabel;
  final void Function(String tool, bool? on) onChanged;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    key: PageStorageKey<String>(storageKey),
    shape: const Border(),
    collapsedShape: const Border(),
    tilePadding: EdgeInsets.zero,
    dense: true,
    childrenPadding: const EdgeInsets.only(left: Insets.md),
    expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
    title: Text(
      'Advanced: ${group.label}',
      style: SettingsStyles.rowHelp(context),
    ),
    children: [
      for (final tool in group.tools)
        SettingsRow(
          key: ValueKey('$storageKey:$tool'),
          label: tool,
          control: ToolAccessLevelPicker(
            value: levelOf(tool),
            unsetLabel: unsetLabel,
            onChanged: (on) => onChanged(tool, on),
          ),
        ),
    ],
  );
}

/// Unset, On or Off: a level's own override, null where it inherits.
class ToolAccessLevelPicker extends StatelessWidget {
  const ToolAccessLevelPicker({
    required this.value,
    required this.unsetLabel,
    required this.onChanged,
    super.key,
  });

  final bool? value;

  /// What unset means here: Default globally, Inherit for a project.
  final String unsetLabel;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) => CompactSegmented<_Level>(
    segments: [
      ButtonSegment(value: _Level.unset, label: _label(unsetLabel)),
      ButtonSegment(value: _Level.on, label: _label('On')),
      ButtonSegment(value: _Level.off, label: _label('Off')),
    ],
    selected: switch (value) {
      null => _Level.unset,
      true => _Level.on,
      false => _Level.off,
    },
    onChanged: (level) => onChanged(switch (level) {
      _Level.unset => null,
      _Level.on => true,
      _Level.off => false,
    }),
  );

  static Widget _label(String text) => FittedBox(
    fit: BoxFit.scaleDown,
    child: Text(text, maxLines: 1, softWrap: false),
  );
}

enum _Level { unset, on, off }

/// The switches follow the server, so a refusal leaves them where they were
/// and only the reason needs saying.
void _write(BuildContext context, WidgetRef ref, McpToolAccessPolicy policy) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  unawaited(
    ref.read(toolAccessActionsProvider).set(policy).catchError((Object error) {
      if (error is! DataRefused) throw error;
      messenger?.showSnackBar(SnackBar(content: Text(error.message)));
    }),
  );
}
