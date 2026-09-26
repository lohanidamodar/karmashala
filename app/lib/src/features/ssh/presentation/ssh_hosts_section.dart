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
import '../../files/application/files_tab_actions.dart';
import '../application/ssh_hosts_controller.dart';
import 'package:karmashala_ssh/connection.dart';
import 'ssh_connection_status_chip.dart';
import 'host_install_panel.dart';
import 'host_sessions_dialog.dart';
import 'pair_phone_dialog.dart';
import 'pair_phone_entry.dart';
import 'ssh_host_dialog.dart';

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
              'No remote hosts yet. Passwords and passphrases are never saved.',
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
      ref
          .read(terminalSessionsControllerProvider.notifier)
          .openTab(
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
          value: 'sessions',
          label: 'Sessions on this host…',
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
        DesktopMenuItem(
          value: 'pair_phone',
          label: kPairPhoneLabel,
          icon: AppIcons.deviceMobile,
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
        'sessions' => HostSessionsDialog.show(context, host: host),
        'new_project' => NewProjectDialog.show(
          context,
          initialEnvironmentId: host.environmentId,
        ),
        'browse' => openFilesTabOn(ref, host.environmentId),
        'edit' => SshHostDialog.show(context, existing: host),
        'pair_phone' => PairPhoneDialog.show(context, host: host),
        _ => _remove(context, ref),
      },
      builder: (context) => SettingsCard(
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
                      // The name gives way; the count beside it does not.
                      Flexible(
                        child: Text(
                          host.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      if (projects.isNotEmpty) ...[
                        const SizedBox(width: Insets.xs),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Insets.xs,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(Radii.md),
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
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
                  onPressed: () => openFilesTabOn(ref, host.environmentId),
                  icon: const Icon(AppIcons.folderOpen),
                  label: const Text('Browse files'),
                ),
                TextButton.icon(
                  onPressed: () => PairPhoneDialog.show(context, host: host),
                  icon: const Icon(AppIcons.deviceMobile),
                  label: const Text(kPairPhoneLabel),
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
            const Divider(height: Insets.lg),
            HostInstallPanel(host: host),
          ],
        ),
      ),
    );
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(sshHostsControllerProvider.notifier);
    final holding = await controller.projectsHolding(host.id);
    if (!context.mounted) return;
    if (holding.isNotEmpty) return _explainInUse(context, holding);

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
    try {
      await controller.remove(host.id);
    } on SshHostInUse catch (inUse) {
      // A project created on the host while the dialog was open.
      if (context.mounted) await _explainInUse(context, inUse.projects);
    }
  }

  /// The store will not orphan a project, so the host cannot go before they
  /// do. Named, so the user knows exactly what to remove.
  Future<void> _explainInUse(BuildContext context, List<String> projects) {
    final named = projects.map((p) => '• $p').join('\n');
    final one = projects.length == 1;
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${host.name} still has projects'),
        content: Text(
          '${one ? 'This project uses' : 'These projects use'} ${host.name}:'
          '\n\n$named\n\n'
          'Remove ${one ? 'it' : 'them'} from Karmashala first, then remove '
          'the host.',
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}
