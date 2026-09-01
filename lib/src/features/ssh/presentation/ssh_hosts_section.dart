import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
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
        icon: const Icon(AppIcons.plus, size: 16),
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

class _HostCard extends ConsumerWidget {
  const _HostCard({required this.host});

  final SshHost host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final key = host.privateKey;

    return Card(
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
                  size: 18,
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
              style: const TextStyle(fontFamily: kMonoFamily, fontSize: 12),
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
                  icon: const Icon(AppIcons.folderOpen, size: 16),
                  label: const Text('Browse files'),
                ),
                TextButton.icon(
                  onPressed: () => SshHostDialog.show(context, existing: host),
                  icon: const Icon(AppIcons.pencilSimple, size: 16),
                  label: const Text('Edit'),
                ),
                TextButton.icon(
                  onPressed: () => _remove(context, ref),
                  icon: const Icon(AppIcons.trash, size: 16),
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
