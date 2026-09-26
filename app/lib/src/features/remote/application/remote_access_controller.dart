/// Brings the phone companion in line with the settings. The Remote access
/// settings are the server's config (`server.json`, [remoteAccessSettingsProvider])
/// and the server serves the phones by it; this app writes what only it knows
/// into it (its SSH hosts' relays, the Notes switch) and tells it where the
/// app's embedded relay listens. The relays are independent: turning one off
/// *parks* its devices, restarting nothing.
library;

import 'dart:async';

import 'package:karmashala_host/lifecycle_client.dart'
    show CompanionNoticeKind, CompanionNoticeMessage;
import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused;
import '../../../core/probe/probe_mode.dart';
import '../../notes/application/notes_providers.dart';
import '../../notifications/application/attention_inbox.dart';
import '../../notifications/application/notification_providers.dart';
import 'package:karmashala_notifications/attention.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/domain/settings.dart';
import 'package:karmashala_remote/remote.dart';
import '../relay_local/local_relay_providers.dart';
import 'host_companion_link.dart';
import 'host_companion_providers.dart';
import 'pairing_in_progress.dart';
import 'relay_prefs.dart';
import 'remote_access_settings.dart';
import 'ssh_relays.dart';
import 'remote_providers.dart';

/// The relay PopupBits runs, used until the user points at their own.
const String kDefaultRelayUrl = 'wss://relay.popupbits.com';

/// The relay URL to dial: the user's setting when it parses, the PopupBits
/// default otherwise.
Uri resolveRelayUri(String? configured) {
  final text = configured?.trim() ?? '';
  if (text.isEmpty) return Uri.parse(kDefaultRelayUrl);
  final parsed = Uri.tryParse(text);
  if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
    return Uri.parse(kDefaultRelayUrl);
  }
  return parsed;
}

/// The internet relay the server's config names, or the PopupBits one.
Uri hostedRelayOf(RemoteAccessSettings settings) =>
    settings.relay ?? Uri.parse(kDefaultRelayUrl);

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
  }) async {
    final current = _ref.read(remoteAccessSettingsProvider);
    final relay = relayUrl == null
        ? null
        : resolveRelayUri(relayUrl).toString();
    final companion = <String, Object?>{
      'enabled': ?enabled,
      'relayEnabled': ?hostedEnabled,
      if (relay != null) ...{'relay': relay, 'relayToken': null},
      if (enabled == true) ...{
        'bind': '0.0.0.0',
        'beacon': true,
        // The internet relay the desktop has always offered, until the
        // person names another.
        if (relay == null && current.relay == null) 'relay': kDefaultRelayUrl,
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

  /// Gives the server's config what only this app knows, and tells the server
  /// where this app's embedded relay is — or stops that relay when remote
  /// access is off, or no link to the server's companion is open.
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
    final settings = _ref.read(settingsControllerProvider);
    final host = _host;
    final remote = _ref.read(remoteAccessSettingsProvider.notifier);
    if (!_ref.read(remoteAccessSettingsProvider).loaded) await remote.load();
    final access = _ref.read(remoteAccessSettingsProvider);
    // A probe binds no relay port, opens no firewall rule and dials no relay:
    // the phone is paired to the real app, and 8787 is its port.
    if (!access.enabled || isDisabledByProbe || host == null) {
      await _stopLocalRelay();
      host?.setLocalRelay(null);
      return;
    }
    final prefs = _ref.read(relayPrefsProvider);
    // The embedded relay is this app's own, brought to what its prefs ask.
    final localUrl = await _syncLocalRelay(settings, prefs);
    final sshRelays = _ref.read(activeSshRelayUrlsProvider);
    final notes = _ref.read(notesEnabledProvider);
    if (access.notes != notes || !_sameUris(access.extraRelays, sshRelays)) {
      await remote.update({'companion': _appOwned()});
    }
    host.setLocalRelay(localUrl);
  }

  /// Starts or stops the embedded relay to match the prefs, answering where it
  /// can be dialled; null when it is off or failed to bind.
  Future<Uri?> _syncLocalRelay(Settings settings, RelayPrefs prefs) async {
    final localRelay = _ref.read(localRelayServiceProvider);
    if (!prefs.localEnabled) {
      await localRelay.stop();
      return null;
    }
    await localRelay.ensureRunning(settings.localRelayPort);
    if (!localRelay.isRunning) return null; // The bind failed; status says why.
    // No LAN address (a machine with no network): loopback keeps the host
    // consistent until the next sync finds one.
    return localRelay.status.primaryUrl ??
        Uri(
          scheme: 'ws',
          host: '127.0.0.1',
          port: localRelay.status.boundPort ?? settings.localRelayPort,
        );
  }

  Future<void> _stopLocalRelay() => _ref.read(localRelayServiceProvider).stop();

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

  /// The lifecycle teardown: the embedded relay stops with the app.
  Future<void> shutdown() {
    _chain = _chain.then((_) => _stopLocalRelay()).catchError((Object _) {});
    return _chain;
  }

  /// Where the desktop's news goes: the server's companion, over the link.
  _CompanionNews? get _news {
    final host = _host;
    return host == null ? null : _HostNews(host);
  }

  void onSessionsMoved() => _news?.sessionsMoved();

  void onAttention(
    List<SessionAttention>? previous,
    List<SessionAttention> next,
  ) {
    final news = _news;
    if (news == null) return;
    news.sessionsMoved();
    final before = {
      for (final attention in previous ?? const <SessionAttention>[])
        if (attention.kind == AttentionKind.needsInput)
          attention.session.openId,
    };
    for (final attention in next) {
      if (attention.kind != AttentionKind.needsInput) continue;
      if (attention.session.imported) continue;
      if (before.contains(attention.session.openId)) continue;
      news.approvalRequested(attention.session.openId);
    }
  }

  /// New attention-inbox items become sealed pushes for paired phones with no
  /// live link; connected phones already heard it as `session.changed`.
  void onInboxChanged(AttentionInbox? previous, AttentionInbox next) {
    final news = _news;
    if (news == null) return;
    final before = {
      for (final item in previous?.items ?? const <InboxItem>[]) item.id,
    };
    var limitFiled = false;
    for (final item in next.items) {
      if (before.contains(item.id)) continue;
      if (item.session.imported) continue;
      final kind = switch (item.kind) {
        InboxItemKind.finished => 'finished',
        InboxItemKind.needsApproval => 'needs_approval',
        InboxItemKind.failed => 'failed',
        InboxItemKind.usageLimit => kAttentionUsageLimit,
        // Delivery news and follow-ups stay on the desktop in v1: what a
        // session left behind is to sit down with, not a buzz in a pocket.
        InboxItemKind.checksFailed ||
        InboxItemKind.changesRequested ||
        InboxItemKind.readyToMerge ||
        InboxItemKind.followUp => null,
      };
      if (kind == null) continue;
      if (item.kind == InboxItemKind.usageLimit) limitFiled = true;
      news.attention(
        sessionId: item.session.openId,
        title: item.session.label,
        kind: kind,
        // "Codex hit its 5-hour limit. Resets 14:05." — the reset is the news.
        detail: item.kind == InboxItemKind.usageLimit ? item.detail : null,
      );
    }
    // A limit is carried on the session's snapshot, which nothing else moves
    // when it is filed; a connected phone hears it from this sweep.
    if (limitFiled) news.sessionsMoved();
  }
}

bool _sameUris(List<Uri> a, List<Uri> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].toString() != b[i].toString()) return false;
  }
  return true;
}

/// The desktop's news for phones, whichever server carries it.
abstract interface class _CompanionNews {
  void sessionsMoved();
  void approvalRequested(String sessionId);
  void attention({
    required String sessionId,
    required String title,
    required String kind,
    String? detail,
  });
}

/// The session host's server, told over the lifecycle link.
class _HostNews implements _CompanionNews {
  _HostNews(this._host);
  final HostCompanionLink _host;

  @override
  void sessionsMoved() => _host.notice(
    const CompanionNoticeMessage(CompanionNoticeKind.sessionsMoved),
  );

  @override
  void approvalRequested(String sessionId) => _host.notice(
    CompanionNoticeMessage(
      CompanionNoticeKind.approvalRequested,
      sessionId: sessionId,
    ),
  );

  @override
  void attention({
    required String sessionId,
    required String title,
    required String kind,
    String? detail,
  }) => _host.notice(
    CompanionNoticeMessage(
      CompanionNoticeKind.attention,
      sessionId: sessionId,
      title: title,
      attention: kind,
      detail: detail,
    ),
  );
}

/// The one controller. Read it once at bootstrap so an enabled setting starts
/// the service; the settings section reads it to toggle, pair and revoke.
final remoteAccessControllerProvider = Provider<RemoteAccessController>((ref) {
  final controller = RemoteAccessController(ref);
  // The desktop's own change signals, fanned out to every connected phone.
  ref.listen(sessionsRevisionProvider, (_, _) => controller.onSessionsMoved());
  ref.listen(
    sessionAttentionProvider,
    (previous, next) => controller.onAttention(previous, next),
  );
  ref.listen(
    attentionInboxProvider,
    (previous, next) => controller.onInboxChanged(previous, next),
  );
  // The host answers `notes.get` itself, by its config's switch, which this
  // keeps in step with the app's.
  ref.listen(notesEnabledProvider, (_, _) => unawaited(controller.sync()));
  ref.onDispose(() {
    unawaited(controller.shutdown());
  });
  // Bring the service up if the user had it enabled last run.
  unawaited(controller.sync());
  return controller;
});
