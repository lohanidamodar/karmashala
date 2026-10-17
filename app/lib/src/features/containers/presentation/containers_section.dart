import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_containers/karmashala_containers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/ssh.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/panes.dart' show StatusDot;
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../files/application/files_tab_actions.dart';
import '../../projects/presentation/new_project_dialog.dart';
import '../../settings/presentation/settings_section.dart';
import '../../settings/presentation/settings_theme.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../application/container_creations_controller.dart';
import 'new_container_dialog.dart';

/// **CONTAINERS**: the Linux containers Karmashala made, each a machine reached
/// through its host, and the ones being made, with their progress and log.
class ContainersSection extends ConsumerWidget {
  const ContainersSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final creations = ref.watch(containerCreationsControllerProvider);
    final machines = ref.watch(containerMachinesProvider);
    return SettingsSection(
      title: 'CONTAINERS',
      trailing: TextButton.icon(
        key: const ValueKey('containers-new'),
        onPressed: () => NewContainerDialog.show(context),
        icon: const Icon(AppIcons.plus),
        label: const Text('New container'),
      ),
      child: creations.isEmpty && machines.isEmpty
          ? const SettingsNote(
              'No containers yet. A container is a stock Linux distribution '
              'on an SSH host with Docker or in WSL, reached through it.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final creation in creations.values)
                  _CreationRow(creation: creation),
                for (final machine in machines) _MachineRow(host: machine),
              ],
            ),
    );
  }
}

/// A container being made: its step, a bar, and its latest log lines.
class _CreationRow extends ConsumerStatefulWidget {
  const _CreationRow({required this.creation});

  final ContainerCreation creation;

  @override
  ConsumerState<_CreationRow> createState() => _CreationRowState();
}

class _CreationRowState extends ConsumerState<_CreationRow> {
  bool _showLog = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final creation = widget.creation;
    final controller = ref.read(containerCreationsControllerProvider.notifier);
    final index = kCreationSteps.indexOf(creation.step);
    final stepLabel = creation.failed
        ? 'Failed'
        : 'Creating · ${index < 0 ? kCreationSteps.length : index + 1} of '
              '${kCreationSteps.length}';
    return SettingsCard(
      key: ValueKey('container-creating-${creation.machineId}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (creation.failed)
                Icon(
                  AppIcons.warningCircle,
                  size: Chrome.iconSmall,
                  color: semantic.failure,
                )
              else
                const InlineSpinner(),
              const SizedBox(width: Insets.sm),
              Expanded(child: _NameOnHost(creation.name, creation.hostName)),
              const SizedBox(width: Insets.sm),
              Flexible(
                child: Text(
                  stepLabel,
                  textAlign: TextAlign.end,
                  style: SettingsStyles.rowHelp(
                    context,
                  )?.copyWith(color: creation.failed ? semantic.failure : null),
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          if (!creation.failed)
            LinearProgressIndicator(
              value: index < 0 ? null : (index + 1) / kCreationSteps.length,
            )
          else
            Text(
              creation.error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: semantic.failure,
              ),
            ),
          if (_showLog && creation.log.isNotEmpty) ...[
            const SizedBox(height: Insets.xs),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Insets.sm),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Text(
                creation.log.join('\n'),
                style: MonoStyles.body.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          const SizedBox(height: Insets.xs),
          Wrap(
            spacing: Insets.xs,
            runSpacing: Insets.xs,
            children: [
              if (creation.log.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() => _showLog = !_showLog),
                  child: Text(_showLog ? 'Hide log' : 'Show log'),
                ),
              if (creation.failed)
                TextButton(
                  onPressed: () => controller.dismiss(creation.machineId),
                  child: const Text('Dismiss'),
                )
              else
                TextButton(
                  key: ValueKey('container-cancel-${creation.machineId}'),
                  onPressed: () => controller.cancel(creation.machineId),
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  child: const Text('Cancel and remove'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// `sandbox-1 · on build-box`, the name giving way first.
class _NameOnHost extends StatelessWidget {
  const _NameOnHost(this.name, this.hostName);

  final String name;
  final String? hostName;

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      text: name,
      style: SettingsStyles.rowLabel(context),
      children: [
        if (hostName != null)
          TextSpan(
            text: ' · on $hostName',
            style: SettingsStyles.rowHelp(context),
          ),
      ],
    ),
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
  );
}

/// What a container's state reads as, and the colour of its dot.
({String label, Color color}) describeContainerState(
  BuildContext context,
  ContainerState? state,
) {
  final semantic = SemanticColors.of(context);
  final outline = Theme.of(context).colorScheme.outline;
  return switch (state) {
    null => (label: 'Checking…', color: outline),
    ContainerState.running => (label: 'Running', color: semantic.idle),
    ContainerState.stopped => (label: 'Stopped', color: outline),
    ContainerState.starting => (label: 'Starting', color: semantic.working),
    ContainerState.paused => (label: 'Paused', color: semantic.attention),
    ContainerState.missing => (label: 'Gone', color: semantic.failure),
    ContainerState.unknown => (label: 'Unknown', color: outline),
  };
}

/// A container machine: its host, what it was made with, where it stands,
/// Terminal or Start, and the rest in its menu.
class _MachineRow extends ConsumerStatefulWidget {
  const _MachineRow({required this.host});

  final SshHost host;

  @override
  ConsumerState<_MachineRow> createState() => _MachineRowState();
}

class _MachineRowState extends ConsumerState<_MachineRow> {
  bool _busy = false;

  SshHost get host => widget.host;

  Future<void> _act(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on DataRefused catch (refusal) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(refusal.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openTerminal() {
    final terminals = ref.read(terminalSessionsControllerProvider.notifier);
    terminals.openTab(TerminalProfile.ssh(host.id, hostName: host.name));
    terminals.showTerminalHere();
  }

  Future<void> _delete() async {
    final withHome = await DeleteContainerDialog.show(context, host: host);
    if (withHome == null || !mounted) return;
    await _act(
      () => ref
          .read(containerActionsProvider)
          .delete(host.id, withHome: withHome),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final container = host.container!;
    final hostName = ref.watch(
      environmentNameProvider(container.environmentId),
    );
    final state = ref.watch(containerStateProvider(host.id)).value;
    final described = describeContainerState(context, state);
    final running = state == ContainerState.running;
    final actions = ref.read(containerActionsProvider);
    final facts = [
      ContainerDistro.forImage(container.image)?.label ?? container.image,
      '${container.cpus} CPU${container.cpus == 1 ? '' : 's'}',
      formatMemory(container.memoryMb),
      for (final name in container.agents)
        ContainerAgentCli.byName(name)?.label ?? name,
    ].join(' · ');

    return RowContextMenu(
      menuLabel: 'Actions for ${host.name}',
      itemBuilder: () => _menu(running),
      onSelected: (value) => _select(value, actions),
      builder: (context) => SettingsCard(
        key: ValueKey('container-${host.id}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  AppIcons.package,
                  size: Chrome.iconSmall,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: Insets.sm),
                Expanded(child: _NameOnHost(host.name, hostName)),
                const SizedBox(width: Insets.sm),
                StatusDot(color: described.color, label: described.label),
                const SizedBox(width: Insets.xs),
                Flexible(
                  child: Text(
                    described.label,
                    style: SettingsStyles.rowHelp(context),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Insets.xs),
            Text(facts, style: SettingsStyles.rowHelp(context)),
            const SizedBox(height: Insets.sm),
            Wrap(
              spacing: Insets.xs,
              runSpacing: Insets.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (running)
                  FilledButton.tonalIcon(
                    key: ValueKey('container-terminal-${host.id}'),
                    onPressed: _busy ? null : _openTerminal,
                    icon: const Icon(AppIcons.terminal),
                    label: const Text('Terminal'),
                  )
                else
                  FilledButton.tonalIcon(
                    key: ValueKey('container-start-${host.id}'),
                    onPressed: _busy
                        ? null
                        : () => _act(
                            () => actions.power(
                              host.id,
                              ContainerPowerAction.start,
                            ),
                          ),
                    icon: _busy
                        ? const InlineSpinner()
                        : const Icon(AppIcons.play),
                    label: const Text('Start'),
                  ),
                RowMenuButton(
                  tooltip: 'More for ${host.name}',
                  itemBuilder: () => _menu(running),
                  onSelected: (value) => _select(value, actions),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<PopupMenuEntry<String>> _menu(bool running) => [
    if (running) ...[
      DesktopMenuItem(
        value: 'terminal',
        label: 'Terminal',
        icon: AppIcons.terminal,
      ),
      DesktopMenuItem(
        value: 'new_project',
        label: 'New project…',
        icon: AppIcons.folderPlus,
      ),
      DesktopMenuItem(
        value: 'browse',
        label: 'Browse files',
        icon: AppIcons.folderOpen,
      ),
      DesktopMenuItem(value: 'stop', label: 'Stop', icon: AppIcons.stop),
    ] else
      DesktopMenuItem(value: 'start', label: 'Start', icon: AppIcons.play),
    const DesktopMenuDivider(),
    DesktopMenuItem(
      value: 'delete',
      label: 'Delete…',
      icon: AppIcons.trash,
      destructive: true,
    ),
  ];

  void _select(String value, ContainerActions actions) => switch (value) {
    'terminal' => _openTerminal(),
    'new_project' => NewProjectDialog.show(
      context,
      initialEnvironmentId: host.environmentId,
    ),
    'browse' => openFilesTabOn(ref, host.environmentId),
    'stop' => _act(() => actions.power(host.id, ContainerPowerAction.stop)),
    'start' => _act(() => actions.power(host.id, ContainerPowerAction.start)),
    _ => _delete(),
  };
}

/// "Delete `name`?", with whether its home folder goes too. Answers that
/// choice, or null for Cancel.
class DeleteContainerDialog extends StatefulWidget {
  const DeleteContainerDialog({required this.host, super.key});

  final SshHost host;

  static Future<bool?> show(BuildContext context, {required SshHost host}) =>
      showDialog<bool>(
        context: context,
        builder: (_) => DeleteContainerDialog(host: host),
      );

  @override
  State<DeleteContainerDialog> createState() => _DeleteContainerDialogState();
}

class _DeleteContainerDialogState extends State<DeleteContainerDialog> {
  bool _withHome = false;

  @override
  Widget build(BuildContext context) {
    final container = widget.host.container!;
    return AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.trash,
        title: 'Delete ${widget.host.name}?',
      ),
      content: BoundedDialogContent(
        width: DialogWidth.narrow,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The container ${container.name} is removed from its host, and '
              'Karmashala forgets its key and its pinned host key.',
            ),
            const SizedBox(height: Insets.sm),
            CheckboxListTile(
              key: const ValueKey('container-delete-home'),
              value: _withHome,
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Also delete its home folder (the volume)'),
              subtitle: const Text(
                'Leave it to keep your files for a container of the same '
                'name.',
              ),
              onChanged: (on) => setState(() => _withHome = on ?? false),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        DestructiveButton(
          key: const ValueKey('container-delete-confirm'),
          onPressed: () => Navigator.of(context).pop(_withHome),
          child: const Text('Delete'),
        ),
      ],
    );
  }
}
