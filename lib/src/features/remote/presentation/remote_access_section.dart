import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/presentation/settings_section.dart';
import '../application/relay_prefs.dart';
import '../application/remote_access_controller.dart';
import '../application/remote_providers.dart';
import 'package:karmashala_remote/remote.dart';
import '../relay_local/local_relay_providers.dart';
import '../relay_local/local_relay_service.dart';
import 'pairing_dialog.dart';

/// Settings → Remote access: the enable switch, the two independent relays
/// (the embedded local one with its start/stop, and a hosted one), the paired
/// devices with last-seen, their relay and revoke, and the pairing button.
class RemoteAccessSection extends ConsumerStatefulWidget {
  const RemoteAccessSection({super.key});

  @override
  ConsumerState<RemoteAccessSection> createState() =>
      _RemoteAccessSectionState();
}

class _RemoteAccessSectionState extends ConsumerState<RemoteAccessSection> {
  final _relay = TextEditingController();
  final _port = TextEditingController();

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsControllerProvider);
    _relay.text = settings.remoteRelayUrl ?? '';
    _port.text = '${settings.localRelayPort}';
  }

  @override
  void dispose() {
    _relay.dispose();
    _port.dispose();
    super.dispose();
  }

  void _setEnabled(bool value) {
    ref.read(settingsControllerProvider.notifier).setRemoteAccessEnabled(value);
    ref.read(remoteAccessControllerProvider).sync();
  }

  /// Start/stop the embedded relay. Persisted, so it auto-starts with remote
  /// access on later launches; the hosted relay is untouched by this.
  void _setLocalEnabled(bool value) {
    ref.read(relayPrefsProvider.notifier).setLocalEnabled(value);
    ref.read(remoteAccessControllerProvider).sync();
  }

  /// Turn the hosted relay on or off. Its devices park while it is off.
  void _setHostedEnabled(bool value) {
    ref.read(relayPrefsProvider.notifier).setHostedEnabled(value);
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

  /// The local port, applied when editing ends; junk snaps back.
  void _applyPort() {
    final settings = ref.read(settingsControllerProvider);
    final parsed = int.tryParse(_port.text.trim());
    if (parsed == null || parsed < 1 || parsed > 65535) {
      _port.text = '${settings.localRelayPort}';
      return;
    }
    if (parsed == settings.localRelayPort) return;
    ref.read(settingsControllerProvider.notifier).setLocalRelayPort(parsed);
    ref.read(remoteAccessControllerProvider).sync();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsControllerProvider);
    final prefs = ref.watch(relayPrefsProvider);
    final devices = ref.watch(pairedDevicesProvider);
    // A device is parked while the relay it was paired through is off: the
    // row says so instead of leaving "last seen" to imply it is served.
    final localLive =
        prefs.localEnabled &&
        ref.watch(localRelayStatusProvider).state == LocalRelayState.running;

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
            // Two independent relays: any combination is legal, and a phone
            // is served on whichever one it was paired through.
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: prefs.localEnabled,
              onChanged: _setLocalEnabled,
              secondary: const Icon(AppIcons.terminalWindow),
              title: const Text('Local relay (this computer)'),
              subtitle: const Text(
                'Runs on this computer for phones on the same network. No '
                'server of your own, nothing leaves the house.',
              ),
            ),
            if (prefs.localEnabled) ...[
              const _LocalRelayStatusRow(),
              const SizedBox(height: Insets.sm),
              Row(
                children: [
                  SizedBox(
                    width: 120,
                    child: TextField(
                      controller: _port,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'Port',
                      ),
                      onSubmitted: (_) => _applyPort(),
                      onEditingComplete: _applyPort,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: Insets.sm),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: prefs.hostedEnabled,
              onChanged: _setHostedEnabled,
              secondary: const Icon(AppIcons.globe),
              title: const Text('Hosted relay (internet)'),
              subtitle: const Text(
                'Reaches a phone anywhere. The relay only forwards sealed '
                'frames — it can read nothing.',
              ),
            ),
            if (prefs.hostedEnabled)
              TextField(
                controller: _relay,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Relay URL',
                  hintText: kDefaultRelayUrl,
                  helperText:
                      'Leave empty for the PopupBits relay, or point it at '
                      'your own.',
                ),
                onChanged: _saveRelay,
                onSubmitted: (_) => _applyRelay(),
                onEditingComplete: _applyRelay,
              ),
            if (!prefs.anyEnabled)
              Padding(
                padding: const EdgeInsets.only(top: Insets.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      AppIcons.warningCircle,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: Insets.xs),
                    Expanded(
                      child: Text(
                        'No relay is switched on, so remote access is idle: '
                        'paired phones can only reach this computer over the '
                        'local network, and no new device can be paired.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
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
              for (final device in devices)
                _DeviceRow(
                  device: device,
                  parked: device.pairedViaLocalRelay
                      ? !localLive
                      : !prefs.hostedEnabled,
                ),
          ],
        ],
      ),
    );
  }
}

/// What the embedded relay is doing: the ws URL a phone dials, the other
/// addresses, the bind error with a retry, and the firewall hint.
class _LocalRelayStatusRow extends ConsumerWidget {
  const _LocalRelayStatusRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = ref.watch(localRelayStatusProvider);
    final primary = status.primaryUrl;

    final (IconData icon, Color color, String message) = switch (status.state) {
      LocalRelayState.running when primary != null => (
        AppIcons.checkCircle,
        scheme.primary,
        'Relay running at $primary',
      ),
      LocalRelayState.running => (
        AppIcons.warningCircle,
        scheme.error,
        'Relay running on port ${status.boundPort}, but this computer has no '
            'local network address a phone could dial.',
      ),
      LocalRelayState.error => (
        AppIcons.warningCircle,
        scheme.error,
        'Local relay: ${status.error}',
      ),
      LocalRelayState.stopped => (
        AppIcons.pauseCircle,
        scheme.onSurfaceVariant,
        'Local relay is starting…',
      ),
    };

    final others = [
      for (final endpoint in status.endpoints)
        if (!endpoint.primary) '${endpoint.url}',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const SizedBox(width: Insets.xs),
            Expanded(child: Text(message, style: theme.textTheme.bodySmall)),
            if (status.state == LocalRelayState.error)
              TextButton(
                onPressed: () =>
                    ref.read(remoteAccessControllerProvider).sync(),
                child: const Text('Retry'),
              ),
          ],
        ),
        if (others.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Text(
              'Also reachable at ${others.join(', ')}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        if (status.firewallHint)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Text(
              "If the phone can't connect, allow Karmashala in Windows "
              'Defender Firewall.',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

class _DeviceRow extends ConsumerWidget {
  const _DeviceRow({required this.device, this.parked = false});

  final PairedDevice device;

  /// The relay this device was paired through is switched off, so only a
  /// direct LAN link reaches it. It resumes when that relay returns.
  final bool parked;

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
                  device.revoked
                      ? 'Revoked'
                      : [
                          device.pairedViaLocalRelay
                              ? 'Local relay'
                              : 'Hosted relay',
                          if (parked) 'paused — that relay is off',
                          _lastSeen(device.lastSeenAt),
                        ].join(' · '),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: parked && !device.revoked
                        ? scheme.error
                        : scheme.onSurfaceVariant,
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
