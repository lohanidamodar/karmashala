/// Brings the phone companion in line with the settings. The Remote access
/// settings are the server's config (`server.json`, [remoteAccessSettingsProvider])
/// and the server serves the phones by it — its LAN relay included, which it
/// hosts itself; this app writes what only it knows into it (its SSH hosts'
/// relays, the Notes switch). The relays are independent: turning one off
/// *parks* its devices, restarting nothing.
library;

import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused;
import '../../../core/probe/probe_mode.dart';
import '../../notes/application/notes_providers.dart';
import 'package:karmashala_remote/client.dart' show defaultCompanionRelay;
import 'package:karmashala_remote/remote.dart';
import 'host_companion_link.dart';
import 'host_companion_providers.dart';
import 'pairing_in_progress.dart';
import 'remote_access_settings.dart';
import 'ssh_relays.dart';
import 'remote_providers.dart';

/// The hosted relay this build was given
/// (`--dart-define=KARMASHALA_RELAY_URL=…`), used until the user points at
/// their own. Empty in a source build, which then has no hosted relay.
const String kDefaultRelayUrl = String.fromEnvironment('KARMASHALA_RELAY_URL');

/// The relay URL to dial: the user's setting when it parses, this build's
/// default otherwise, and null when there is neither.
Uri? resolveRelayUri(String? configured) {
  final text = configured?.trim() ?? '';
  final parsed = text.isEmpty ? null : Uri.tryParse(text);
  if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
    return defaultCompanionRelay;
  }
  return parsed;
}

/// The internet relay the server's config names, else this build's default;
/// null when there is neither.
Uri? hostedRelayOf(RemoteAccessSettings settings) =>
    settings.relay ?? defaultCompanionRelay;

class RemoteAccessController {
  RemoteAccessController(this._ref);

  final Ref _ref;

  /// Serialises the syncs so a fast toggle cannot overlap them.
  Future<void> _chain = Future<void>.value();

  /// Whether this instance is a probe, where remote access never starts.
  bool get isDisabledByProbe => _ref.read(probeModeProvider).enabled;

  /// The link to the host's companion, when the host serves the phones.
  HostCompanionLink? get _host => _ref.read(companionAtHostProvider)
      ? _ref.read(hostCompanionLinkProvider)
      : null;

  /// Reads the server's config again, then brings everything in line with it:
  /// a link to a (maybe new) host opened.
  Future<void> reload() async {
    await _ref.read(remoteAccessSettingsProvider.notifier).load();
    await sync();
  }

  /// Changes the Remote access settings — the server's config — and brings
  /// the phone companion in line. Switching remote access on is also what
  /// opens this machine to the LAN: the listener binds every interface and
  /// announces itself on the beacon, as the desktop's phones expect. Throws
  /// with the server's reason when it refuses.
  Future<void> setRemoteAccess({
    bool? enabled,
    bool? hostedEnabled,
    String? relayUrl,
    bool? localRelay,
    int? localRelayPort,
  }) async {
    final current = _ref.read(remoteAccessSettingsProvider);
    final relay = relayUrl == null
        ? null
        : resolveRelayUri(relayUrl)?.toString();
    final companion = <String, Object?>{
      'enabled': ?enabled,
      'relayEnabled': ?hostedEnabled,
      'localRelay': ?localRelay,
      'localRelayPort': ?localRelayPort,
      // A cleared field in a build with no default clears the relay.
      if (relayUrl != null) ...{'relay': relay, 'relayToken': null},
      if (enabled == true) ...{
        'bind': '0.0.0.0',
        'beacon': true,
        // The internet relay this build offers, until the person names
        // another.
        if (relayUrl == null &&
            current.relay == null &&
            kDefaultRelayUrl.isNotEmpty)
          'relay': kDefaultRelayUrl,
        ..._appOwned(),
      },
    };
    await _ref.read(remoteAccessSettingsProvider.notifier).update({
      'companion': companion,
    });
    await sync();
  }

  /// What only this app knows about serving phones, in the config's words:
  /// the relays on its SSH hosts, and whether Notes is on.
  Map<String, Object?> _appOwned() => {
    'extraRelays': [
      for (final uri in _ref.read(activeSshRelayUrlsProvider)) uri.toString(),
    ],
    'notes': _ref.read(notesEnabledProvider),
  };

  /// Gives the server's config what only this app knows, while remote access
  /// is on and a link to the server's companion is open.
  Future<void> sync() {
    _chain = _chain.then((_) => _sync()).catchError((
      Object error,
      StackTrace stack,
    ) {
      // The chain must survive; the failure must not vanish with it.
      _log.error(
        'Remote access could not be brought in line with settings.',
        error,
        stack,
      );
    });
    return _chain;
  }

  static final _log = AppLogger.named('remote.access');

  Future<void> _sync() async {
    final host = _host;
    final remote = _ref.read(remoteAccessSettingsProvider.notifier);
    if (!_ref.read(remoteAccessSettingsProvider).loaded) await remote.load();
    final access = _ref.read(remoteAccessSettingsProvider);
    // A probe writes nothing into the real server's config.
    if (!access.enabled || isDisabledByProbe || host == null) return;
    final sshRelays = _ref.read(activeSshRelayUrlsProvider);
    final notes = _ref.read(notesEnabledProvider);
    if (access.notes != notes || !_sameUris(access.extraRelays, sshRelays)) {
      await remote.update({'companion': _appOwned()});
    }
  }

  /// Shows a new pairing code; throws [StateError] while remote access is off
  /// or no link to the server's companion is open. [relayIsLocal] is what the
  /// device row remembers.
  Future<PairingInProgress> beginPairing({
    required CapabilitySet capabilities,
    Uri? relay,
    bool relayIsLocal = false,
  }) async {
    if (isDisabledByProbe) {
      throw StateError('Remote access is disabled in a probe instance.');
    }
    final host = _host;
    if (host == null) {
      throw StateError(
        'The Karmashala server is not reachable from here, so it cannot pair '
        'a phone now.',
      );
    }
    if (!_ref.read(remoteAccessSettingsProvider).enabled) {
      throw StateError('Turn on remote access first.');
    }
    return host.pair(
      capabilities: capabilities,
      relay: relay,
      relayIsLocal: relayIsLocal,
    );
  }

  Future<void> cancelPairing() async => _host?.cancelPairing();

  /// Renames a paired device: the name is the desktop's own label, which the
  /// phone never learns.
  Future<void> rename(PairedDevice device, String name) => _device(
    'rename',
    _ref.read(pairedDevicesDataProvider).rename(device.id, name),
  );

  /// Changes what a paired device may do, on the link it already holds — no
  /// re-pairing either way. The server applies it to the phone.
  Future<void> updateCapabilities(
    PairedDevice device,
    CapabilitySet capabilities,
  ) => _device(
    'grant',
    _ref.read(pairedDevicesDataProvider).grant(device.id, capabilities),
  );

  /// Revokes a device: the server deletes its key and drops its link.
  Future<void> revoke(PairedDevice device) =>
      _device('revoke', _ref.read(pairedDevicesDataProvider).revoke(device.id));

  /// A device write the server may refuse; the list shows what it holds.
  Future<void> _device(String what, Future<PairedDevice> write) async {
    try {
      await write;
    } on DataRefused catch (refusal) {
      _log.warning('The server refused the device $what: ${refusal.message}');
    }
  }
}

bool _sameUris(List<Uri> a, List<Uri> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].toString() != b[i].toString()) return false;
  }
  return true;
}

/// The one controller. Read it once at bootstrap so an enabled setting starts
/// the service; the settings section reads it to toggle, pair and revoke.
final remoteAccessControllerProvider = Provider<RemoteAccessController>((ref) {
  final controller = RemoteAccessController(ref);
  // The host answers `notes.get` itself, by its config's switch, which this
  // keeps in step with the app's.
  ref.listen(notesEnabledProvider, (_, _) => unawaited(controller.sync()));
  // Bring the service up if the user had it enabled last run.
  unawaited(controller.sync());
  return controller;
});
