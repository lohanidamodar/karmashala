import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/presentation/settings_section.dart';
import '../application/remote_access_controller.dart';
import '../application/remote_providers.dart';
import '../domain/paired_device.dart';
import 'pairing_dialog.dart';

/// Settings → Remote access: the enable switch, the relay, the paired
/// devices with last-seen and revoke, and the pairing button.
class RemoteAccessSection extends ConsumerStatefulWidget {
  const RemoteAccessSection({super.key});

  @override
  ConsumerState<RemoteAccessSection> createState() =>
      _RemoteAccessSectionState();
}

class _RemoteAccessSectionState extends ConsumerState<RemoteAccessSection> {
  final _relay = TextEditingController();

  @override
  void initState() {
    super.initState();
    _relay.text = ref.read(settingsControllerProvider).remoteRelayUrl ?? '';
  }

  @override
  void dispose() {
    _relay.dispose();
    super.dispose();
  }

  void _setEnabled(bool value) {
    ref.read(settingsControllerProvider.notifier).setRemoteAccessEnabled(value);
    ref.read(remoteAccessControllerProvider).sync();
  }

  void _saveRelay(String value) {
    final trimmed = value.trim();
    ref
        .read(settingsControllerProvider.notifier)
        .setRemoteRelayUrl(trimmed.isEmpty ? null : trimmed);
  }

  /// The relay is redialled only when editing ends — not per keystroke.
  void _applyRelay() {
    _saveRelay(_relay.text);
    ref.read(remoteAccessControllerProvider).sync();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsControllerProvider);
    final devices = ref.watch(pairedDevicesProvider);

    return SettingsSection(
      title: 'REMOTE ACCESS',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: settings.remoteAccessEnabled,
            onChanged: _setEnabled,
            title: const Text('Remote access'),
            subtitle: const Text(
              'Let a paired phone view sessions, read transcripts, send '
              'prompts and answer approvals. Everything is end-to-end '
              'encrypted; the relay only forwards sealed frames.',
            ),
          ),
          if (settings.remoteAccessEnabled) ...[
            const SizedBox(height: Insets.sm),
            TextField(
              controller: _relay,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Relay URL',
                hintText: kDefaultRelayUrl,
              ),
              onChanged: _saveRelay,
              onSubmitted: (_) => _applyRelay(),
              onEditingComplete: _applyRelay,
            ),
            const SizedBox(height: Insets.md),
            Row(
              children: [
                Text('Paired devices', style: theme.textTheme.labelMedium),
                const Spacer(),
                FilledButton.icon(
                  onPressed: () => PairingDialog.show(context),
                  icon: const Icon(AppIcons.deviceMobile, size: Chrome.icon),
                  label: const Text('Pair a device'),
                ),
              ],
            ),
            const SizedBox(height: Insets.xs),
            if (devices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Insets.sm),
                child: Text(
                  'No paired devices yet.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              for (final device in devices) _DeviceRow(device: device),
          ],
        ],
      ),
    );
  }
}

class _DeviceRow extends ConsumerWidget {
  const _DeviceRow({required this.device});

  final PairedDevice device;

  static String _lastSeen(DateTime? at) {
    if (at == null) return 'Never connected';
    final since = DateTime.now().toUtc().difference(at);
    if (since.inMinutes < 1) return 'Last seen just now';
    if (since.inHours < 1) return 'Last seen ${since.inMinutes} min ago';
    if (since.inDays < 1) return 'Last seen ${since.inHours} h ago';
    return 'Last seen ${since.inDays} d ago';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Row(
        children: [
          Icon(
            AppIcons.deviceMobile,
            size: Chrome.icon,
            color: device.revoked ? scheme.outline : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device.name,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: device.revoked ? scheme.outline : null,
                  ),
                ),
                Text(
                  device.revoked ? 'Revoked' : _lastSeen(device.lastSeenAt),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (!device.revoked)
            TextButton.icon(
              onPressed: () =>
                  ref.read(remoteAccessControllerProvider).revoke(device),
              icon: const Icon(AppIcons.linkBreak, size: Chrome.iconSmall),
              label: const Text('Revoke'),
              style: TextButton.styleFrom(foregroundColor: scheme.error),
            ),
        ],
      ),
    );
  }
}
