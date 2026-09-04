import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../../../app/widgets/row_menu.dart';
import '../../settings/presentation/settings_section.dart';
import '../application/ssh_hosts_controller.dart';
import '../domain/ssh_host.dart';
import 'ssh_connection_status_chip.dart';
import 'ssh_host_dialog.dart';
import 'remote_file_browser_dialog.dart';

/// The saved remote hosts, and everything you can do to one.
///
/// Remote hosts are the one kind of execution environment that cannot be
/// discovered — there is no probe that finds a machine you have not mentioned —
/// so this list *is* how an SSH environment comes to exist. Adding a host here
/// writes both the host row and its `ssh:<id>` environment.
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

/// One saved host.
///
/// The buttons stay drawn and stay worded: this is a settings form, not a
/// dense list, and "Edit" in words is the interface here rather than the
/// icon-only clutter the row menu exists to remove. What it gains is the other
/// half of the rule — the same actions on a right-click, `Shift+F10` and the
/// Menu key, so a habit learned in the panes is not disappointed here.
class _HostCard extends ConsumerWidget {
  const _HostCard({required this.host});

  final SshHost host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final key = host.privateKey;

    return RowContextMenu(
      menuLabel: 'Actions for ${host.name}',
      itemBuilder: () => [
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
                    child: Text(host.name, style: theme.textTheme.titleSmall),
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
              Row(
                children: [
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
