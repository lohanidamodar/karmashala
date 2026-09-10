import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../settings/presentation/settings_section.dart';
import '../application/known_hosts_controller.dart';
import 'host_key_changed_alert.dart';

/// The host keys that have been pinned, and the one way to unpin one. Shown in
/// full: this list is the record a user checks when a host key changes.
class KnownHostsSection extends ConsumerWidget {
  const KnownHostsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final keys = ref.watch(knownHostsControllerProvider);

    return SettingsSection(
      title: 'TRUSTED HOST KEYS',
      child: keys.isEmpty
          ? Text(
              'None yet. The first time you connect to a host, its fingerprint '
              'is shown and pinned only if you accept it.',
              style: theme.textTheme.bodySmall,
            )
          : Column(
              children: [
                for (final key in keys)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(AppIcons.checkCircle),
                    title: Text('${key.host}:${key.port}'),
                    subtitle: Text(
                      '${key.keyType} · ${key.fingerprint}\n'
                      'trusted ${key.trustedAt.toLocal()}',
                      style: MonoStyles.small,
                    ),
                    isThreeLine: true,
                    trailing: TextButton(
                      onPressed: () => ForgetHostKeyDialog.show(
                        context,
                        host: key.host,
                        port: key.port,
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      child: const Text('Forget'),
                    ),
                  ),
              ],
            ),
    );
  }
}
