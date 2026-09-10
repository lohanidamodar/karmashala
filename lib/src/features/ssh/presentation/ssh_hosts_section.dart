import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import '../../projects/application/projects_controller.dart';
import '../../projects/presentation/new_project_dialog.dart';
import '../../settings/presentation/settings_section.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import '../application/ssh_hosts_controller.dart';
import 'package:karmashala_ssh/connection.dart';
import 'ssh_connection_status_chip.dart';
import 'ssh_host_dialog.dart';
import 'remote_file_browser_dialog.dart';

/// The saved remote hosts, and everything you can do to one. Remote hosts
/// cannot be discovered, so this list *is* how an SSH environment comes to be.
class SshHostsSection extends ConsumerWidget {
  const SshHostsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hosts = ref.watch(sshHostsControllerProvider);

    return SettingsSection(
      title: 'SSH HOSTS',
      trailing: TextButton.icon(
        onPressed: () => SshHostDialog.show(context),
        icon: const Icon(AppIcons.plus),
        label: const Text('Add host'),
      ),
      child: hosts.isEmpty
          ? Text(
              'No remote hosts yet. Add one to run agents on another machine — '
              'its address, account and key location are saved; passwords and '
              'passphrases never are.',
              style: theme.textTheme.bodySmall,
            )
          : Column(children: [for (final host in hosts) _HostCard(host: host)]),
    );
  }
}

/// One saved host. The buttons stay drawn and worded — a settings form, not a
/// dense list — and the same actions are on a right-click and the Menu key.
class _HostCard extends ConsumerWidget {
  const _HostCard({required this.host});

  final SshHost host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final key = host.privateKey;
    final projects = ref
        .watch(projectsControllerProvider)
        .where((p) => p.environmentId == host.environmentId)
        .toList();

    void openTerminal() {
      ref.read(terminalSessionsControllerProvider.notifier).openTab(
        TerminalProfile.ssh(host.id, hostName: host.name),
        workingDirectory: host.defaultDirectory?.path,
      );
      // A new shell opens in the group the keyboard is in.
      ref.read(terminalSessionsControllerProvider.notifier).showTerminalHere();
    }

    return RowContextMenu(
      menuLabel: 'Actions for ${host.name}',
      itemBuilder: () => [
        DesktopMenuItem(
          value: 'terminal',
          label: 'Start terminal',
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
        DesktopMenuItem(
          value: 'edit',
          label: 'Edit',
          icon: AppIcons.pencilSimple,
        ),
        const DesktopMenuDivider(),
        DesktopMenuItem(
          value: 'remove',
          label: 'Remove',
          icon: AppIcons.trash,
          destructive: true,
        ),
      ],
      onSelected: (value) => switch (value) {
        'terminal' => openTerminal(),
        'new_project' => NewProjectDialog.show(
            context,
            initialEnvironmentId: host.environmentId,
          ),
        'browse' => RemoteFileBrowserDialog.show(context, host: host),
        'edit' => SshHostDialog.show(context, existing: host),
        _ => _remove(context, ref),
      },
      builder: (context) => Card(
        margin: const EdgeInsets.only(bottom: Insets.sm),
        child: Padding(
          padding: const EdgeInsets.all(Insets.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    AppIcons.globe,
                    size: Chrome.iconTitle,
                    color: theme.colorScheme.tertiary,
                  ),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Row(
                      children: [
                        Text(host.name, style: theme.textTheme.titleSmall),
                        if (projects.isNotEmpty) ...[
                          const SizedBox(width: Insets.xs),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${projects.length} project${projects.length == 1 ? '' : 's'}',
                              style: theme.textTheme.labelSmall,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  SshConnectionStatusChip(hostId: host.id, showError: false),
                ],
              ),
              const SizedBox(height: Insets.xs),
              Text(
                host.address,
                style: MonoStyles.body,
              ),
              const SizedBox(height: Insets.xs),
              Text(
                switch (host.authMethod) {
                  SshAuthMethod.password => 'Password (asked each connection)',
                  SshAuthMethod.privateKey =>
                    'Key: ${key?.path ?? '—'} (${key?.environmentId ?? '—'})',
                },
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: Insets.sm),
              Wrap(
                spacing: Insets.xs,
                runSpacing: Insets.xs,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: openTerminal,
                    icon: const Icon(AppIcons.terminal),
                    label: const Text('Terminal'),
                  ),
                  TextButton.icon(
                    onPressed: () => NewProjectDialog.show(
                      context,
                      initialEnvironmentId: host.environmentId,
                    ),
                    icon: const Icon(AppIcons.folderPlus),
                    label: const Text('New project'),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        RemoteFileBrowserDialog.show(context, host: host),
                    icon: const Icon(AppIcons.folderOpen),
                    label: const Text('Browse files'),
                  ),
                  TextButton.icon(
                    onPressed: () => SshHostDialog.show(context, existing: host),
                    icon: const Icon(AppIcons.pencilSimple),
                    label: const Text('Edit'),
                  ),
                  TextButton.icon(
                    onPressed: () => _remove(context, ref),
                    icon: const Icon(AppIcons.trash),
                    label: const Text('Remove'),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove ${host.name}?'),
        content: Text(
          'Karmashala will forget how to reach ${host.address} and close any '
          'open connection to it.\n\n'
          'Its trusted host key is kept, so re-adding this machine is not a '
          'silent re-trust: a key that has changed in the meantime is still '
          'refused.',
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(sshHostsControllerProvider.notifier).remove(host.id);
  }
}
