import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../settings/presentation/settings_row.dart';
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

    // Board rows: one per pinned key — host and port as the label, the key
    // under it in the ledger hand, Forget as the row's action.
    return SettingsSection(
      title: 'TRUSTED HOST KEYS',
      child: keys.isEmpty
          ? const SettingsNote(
              'None yet. A host key is pinned only if you accept it.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final key in keys)
                  SettingsRow(
                    label: '${key.host}:${key.port}',
                    helpWidget: Text(
                      '${key.keyType} · ${key.fingerprint}\n'
                      'trusted ${key.trustedAt.toLocal()}',
                      style: MonoStyles.small.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    leading: Icon(
                      AppIcons.checkCircle,
                      size: Chrome.iconSmall,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    control: TextButton(
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
