import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/presentation/settings_section.dart';
import 'package:karmashala_core/logging.dart';

import '../application/relay_prefs.dart';
import '../application/remote_access_controller.dart';
import '../application/remote_access_settings.dart';
import '../application/remote_providers.dart';
import '../application/ssh_relays.dart';
import 'package:karmashala_remote/remote.dart';
import '../relay_local/local_relay_providers.dart';
import '../relay_local/local_relay_service.dart';
import 'device_permissions_dialog.dart';
import 'pairing_dialog.dart';
import 'rename_device_dialog.dart';
import 'ssh_relays_panel.dart';
import '../../settings/presentation/settings_notice.dart';
import '../../settings/presentation/settings_row.dart';

/// Settings → Remote access: the enable switch, the local and hosted relays,
/// the relays on SSH hosts, the paired devices with last-seen and revoke, and
/// the pairing button. The switch, the internet relay and its URL are this
/// machine's server config (`server.json`), read and written through the
/// server; the local relay is this app's own listener.
class RemoteAccessSection extends ConsumerStatefulWidget {
  const RemoteAccessSection({super.key});

  @override
  ConsumerState<RemoteAccessSection> createState() =>
      _RemoteAccessSectionState();
}

class _RemoteAccessSectionState extends ConsumerState<RemoteAccessSection> {
  final _relay = TextEditingController();
  final _port = TextEditingController();

  static final _log = AppLogger.named('remote.settings');

  @override
  void initState() {
    super.initState();
    _relay.text = _relayText(ref.read(remoteAccessSettingsProvider));
    _port.text = '${ref.read(settingsControllerProvider).localRelayPort}';
  }

  /// The URL field's text: empty for the PopupBits relay, as its hint says.
  static String _relayText(RemoteAccessSettings access) {
    final relay = access.relay?.toString();
    return relay == null || relay == kDefaultRelayUrl ? '' : relay;
  }

  /// Writes to the server's config; a refusal is logged, and the switches
  /// show what the server kept.
  Future<void> _change({
    bool? enabled,
    bool? hostedEnabled,
    String? relayUrl,
  }) async {
    try {
      await ref
          .read(remoteAccessControllerProvider)
          .setRemoteAccess(
            enabled: enabled,
            hostedEnabled: hostedEnabled,
            relayUrl: relayUrl,
          );
    } on Object catch (error, stack) {
      _log.warning('Remote access settings were not changed.', error, stack);
    }
  }

  @override
  void dispose() {
    _relay.dispose();
    _port.dispose();
    super.dispose();
  }

  void _setEnabled(bool value) => unawaited(_change(enabled: value));

  /// Start/stop the embedded relay. Persisted, so it auto-starts with remote
  /// access on later launches; the hosted relay is untouched by this.
  void _setLocalEnabled(bool value) {
    ref.read(relayPrefsProvider.notifier).setLocalEnabled(value);
    ref.read(remoteAccessControllerProvider).sync();
  }

  /// Turn the hosted relay on or off. Its devices park while it is off.
  void _setHostedEnabled(bool value) =>
      unawaited(_change(hostedEnabled: value));

  /// The relay is written, and redialled, only when editing ends — not per
  /// keystroke. Empty is the PopupBits relay.
  void _applyRelay() {
    final text = _relay.text.trim();
    if (text == _relayText(ref.read(remoteAccessSettingsProvider))) return;
    unawaited(_change(relayUrl: text));
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
    final access = ref.watch(remoteAccessSettingsProvider);
    // What the server decided replaces the field's text — read late, or
    // changed from elsewhere — unless the person is typing in it.
    ref.listen(remoteAccessSettingsProvider, (previous, next) {
      final text = _relayText(next);
      if (previous != null && _relayText(previous) == text) return;
      _relay.text = text;
    });
    final prefs = ref.watch(relayPrefsProvider);
    final devices = ref.watch(pairedDevicesProvider);
    final sshRelays = ref.watch(sshRelaysProvider);
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
          SettingsSwitchRow(
            label: 'Remote access',
            help: 'Follow and answer sessions from a paired phone. Encrypted.',
            value: access.enabled,
            onChanged: _setEnabled,
          ),
          if (access.enabled) ...[
            const SizedBox(height: Insets.sm),
            _RelaySwitches(
              prefs: prefs,
              hostedEnabled: access.relayEnabled,
              port: _port,
              relay: _relay,
              onLocalChanged: _setLocalEnabled,
              onHostedChanged: _setHostedEnabled,
              onPortDone: _applyPort,
              onRelayDone: _applyRelay,
            ),
            const SizedBox(height: Insets.md),
            const SshRelaysPanel(),
            const SizedBox(height: Insets.md),
            _PairedDevicesList(
              devices: devices,
              relayOf: (device) => _sshRelayOf(device, sshRelays),
              parkedOf: (device) {
                if (device.pairedViaLocalRelay) return !localLive;
                // Its own box relay while that is on; otherwise — and also —
                // the hosted one, which every phone falls back to.
                final box = _sshRelayOf(device, sshRelays);
                return !(box?.enabled ?? false) && !access.relayEnabled;
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// The SSH-host relay [device] was paired through, or null for the local and
/// hosted ones — and for a box that has since been removed.
SshRelayEntry? _sshRelayOf(PairedDevice device, List<SshRelayEntry> relays) {
  final own = device.hostedRelayUri?.toString();
  if (own == null) return null;
  for (final relay in relays) {
    if (relay.url.toString() == own) return relay;
  }
  return null;
}

/// The two independent relays: any combination is legal, and a phone is
/// served on whichever one it was paired through.
class _RelaySwitches extends StatelessWidget {
  const _RelaySwitches({
    required this.prefs,
    required this.hostedEnabled,
    required this.port,
    required this.relay,
    required this.onLocalChanged,
    required this.onHostedChanged,
    required this.onPortDone,
    required this.onRelayDone,
  });

  final RelayPrefs prefs;

  /// Whether the internet relay is served — the server's config.
  final bool hostedEnabled;
  final TextEditingController port;
  final TextEditingController relay;
  final ValueChanged<bool> onLocalChanged;
  final ValueChanged<bool> onHostedChanged;
  final VoidCallback onPortDone;
  final VoidCallback onRelayDone;

  /// A port is five digits; the field need not be wider.
  static const portFieldWidth = 120.0;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSwitchRow(
          label: 'Local relay (this computer)',
          help: 'For phones on the same network.',
          value: prefs.localEnabled,
          onChanged: onLocalChanged,
        ),
        if (prefs.localEnabled) ...[
          const _LocalRelayStatusRow(),
          const SizedBox(height: Insets.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: portFieldWidth,
              child: TextField(
                controller: port,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Port',
                ),
                onSubmitted: (_) => onPortDone(),
                onEditingComplete: onPortDone,
              ),
            ),
          ),
        ],
        const SizedBox(height: Insets.sm),
        SettingsSwitchRow(
          label: 'Hosted relay (internet)',
          help: 'Reaches a phone anywhere. The relay can read nothing.',
          value: hostedEnabled,
          onChanged: onHostedChanged,
        ),
        if (hostedEnabled)
          TextField(
            controller: relay,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Relay URL',
              hintText: kDefaultRelayUrl,
              helperText:
                  'Leave empty for the PopupBits relay, or point it at '
                  'your own.',
            ),
            onSubmitted: (_) => onRelayDone(),
            onEditingComplete: onRelayDone,
          ),
        if (!prefs.localEnabled && !hostedEnabled)
          const Padding(
            padding: EdgeInsets.only(top: Insets.xs),
            child: SettingsNotice(
              tone: SettingsNoticeTone.danger,
              message:
                  'No relay is switched on, so remote access is idle: '
                  'paired phones can only reach this computer over the '
                  'local network, and no new device can be paired.',
            ),
          ),
      ],
    );
  }
}

/// The paired devices under their heading, with the way to pair another.
class _PairedDevicesList extends StatelessWidget {
  const _PairedDevicesList({
    required this.devices,
    required this.parkedOf,
    required this.relayOf,
  });

  final List<PairedDevice> devices;

  /// The box relay [device] was paired through, when it was one.
  final SshRelayEntry? Function(PairedDevice device) relayOf;

  /// Whether the relay [device] was paired through is switched off.
  final bool Function(PairedDevice device) parkedOf;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A Wrap, not a Row with a Spacer: at the narrowest two-column
        // window with bigger text the button goes under the label.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: Insets.sm,
          runSpacing: Insets.xs,
          children: [
            Text('Paired devices', style: theme.textTheme.labelMedium),
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
              parked: parkedOf(device),
              sshRelay: relayOf(device),
            ),
      ],
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

    final (
      IconData icon,
      SettingsNoticeTone tone,
      String message,
    ) = switch (status.state) {
      LocalRelayState.running when primary != null => (
        AppIcons.checkCircle,
        SettingsNoticeTone.positive,
        'Relay running at $primary',
      ),
      LocalRelayState.running => (
        AppIcons.warningCircle,
        SettingsNoticeTone.danger,
        'Relay running on port ${status.boundPort}, but this computer has '
            'no local network address a phone could dial.',
      ),
      LocalRelayState.error => (
        AppIcons.warningCircle,
        SettingsNoticeTone.danger,
        'Local relay: ${status.error}',
      ),
      LocalRelayState.stopped => (
        AppIcons.pauseCircle,
        SettingsNoticeTone.neutral,
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
        SettingsNotice(
          tone: tone,
          icon: icon,
          message: message,
          action: status.state == LocalRelayState.error
              ? TextButton(
                  onPressed: () =>
                      ref.read(remoteAccessControllerProvider).sync(),
                  child: const Text('Retry'),
                )
              : null,
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
  const _DeviceRow({required this.device, this.parked = false, this.sshRelay});

  final PairedDevice device;

  /// The box this phone was paired through, when it was one.
  final SshRelayEntry? sshRelay;

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

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final name = await RenameDeviceDialog.show(context, device.name);
    if (name == null) return;
    ref.read(remoteAccessControllerProvider).rename(device, name);
  }

  Future<void> _permissions(BuildContext context, WidgetRef ref) async {
    final granted = await DevicePermissionsDialog.show(
      context,
      device.name,
      device.capabilities,
    );
    if (granted == null) return;
    await ref
        .read(remoteAccessControllerProvider)
        .updateCapabilities(device, granted);
  }

  /// How much of what this build can grant the device holds — the row says
  /// where a phone stands without opening the dialog.
  static String _grantSummary(CapabilitySet granted) {
    final held = Capability.values.where(granted.has).length;
    if (held == Capability.values.length) return 'all permissions';
    if (held == 0) return 'no permissions';
    return '$held of ${Capability.values.length} permissions';
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
                              : sshRelay != null
                              ? 'Relay on ${sshRelay!.hostName}'
                              : 'Hosted relay',
                          if (parked) 'paused — that relay is off',
                          _grantSummary(device.capabilities),
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
          if (!device.revoked) ...[
            IconButton(
              tooltip: 'Permissions',
              iconSize: Chrome.icon,
              icon: const Icon(AppIcons.listChecks),
              onPressed: () => _permissions(context, ref),
            ),
            IconButton(
              tooltip: 'Rename',
              iconSize: Chrome.icon,
              icon: const Icon(AppIcons.pencilSimple),
              onPressed: () => _rename(context, ref),
            ),
            TextButton.icon(
              onPressed: () =>
                  ref.read(remoteAccessControllerProvider).revoke(device),
              icon: const Icon(AppIcons.linkBreak, size: Chrome.iconSmall),
              label: const Text('Revoke'),
              style: TextButton.styleFrom(foregroundColor: scheme.error),
            ),
          ],
        ],
      ),
    );
  }
}
