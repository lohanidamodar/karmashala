/// Starts and stops [RemoteHostService] to match the settings, and owns the
/// event wiring from the desktop's providers into the fan-out.
///
/// Remote access is OFF by default: nothing here runs until the settings
/// toggle turns it on. `AppLifecycle` calls [shutdown] inside its budget
/// slice, so quitting never waits on a socket.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notifications/application/attention_inbox.dart';
import '../../notifications/application/notification_providers.dart';
import '../../notifications/domain/inbox_item.dart';
import '../../notifications/domain/session_attention.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../domain/paired_device.dart';
import '../pairing/host_pairing.dart';
import '../protocol.dart';
import 'remote_bindings.dart';
import 'remote_host_service.dart';
import 'remote_providers.dart';

/// The relay PopupBits runs, used until the user points at their own.
const String kDefaultRelayUrl = 'wss://relay.popupbits.com';

/// The relay URL to dial: the user's setting when it parses, the PopupBits
/// default otherwise.
Uri resolveRelayUri(String? configured) {
  final text = configured?.trim() ?? '';
  if (text.isEmpty) return Uri.parse(kDefaultRelayUrl);
  final parsed = Uri.tryParse(text);
  if (parsed == null || !parsed.hasScheme) return Uri.parse(kDefaultRelayUrl);
  return parsed;
}

class RemoteAccessController {
  RemoteAccessController(
    this._ref, {
    RemoteHostService Function(Uri relay)? serviceFactory,
    // ignore: prefer_initializing_formals — named for callers.
  }) : _serviceFactory = serviceFactory;

  final Ref _ref;

  /// Test seam: builds the service for [sync]. Null means the real one.
  final RemoteHostService Function(Uri relay)? _serviceFactory;

  RemoteHostService? _service;

  /// Serialises start/stop so a fast toggle cannot overlap them.
  Future<void> _chain = Future<void>.value();

  /// The running service, or null while remote access is off.
  RemoteHostService? get service => _service;

  bool get isRunning => _service?.isRunning ?? false;

  /// Brings the service in line with the settings: started when enabled (and
  /// restarted when the relay URL moved), stopped when disabled.
  Future<void> sync() {
    _chain = _chain.then((_) => _sync()).catchError((Object _) {});
    return _chain;
  }

  Future<void> _sync() async {
    final settings = _ref.read(settingsControllerProvider);
    final relay = resolveRelayUri(settings.remoteRelayUrl);
    if (!settings.remoteAccessEnabled) {
      await _stopService();
      return;
    }
    if (_service != null && _service!.relay == relay) return;
    await _stopService();
    final service =
        _serviceFactory?.call(relay) ??
        RemoteHostService(
          devices: _ref.read(pairedDeviceDaoProvider),
          hostId: _ref.read(hostDeviceIdProvider),
          bindings: _ref.read(remoteHostBindingsProvider),
          relay: relay,
          onDevicesChanged: () =>
              _ref.read(pairedDevicesRevisionProvider.notifier).bump(),
        );
    _service = service;
    await service.start();
  }

  Future<void> _stopService() async {
    final service = _service;
    _service = null;
    if (service != null) await service.stop();
  }

  /// Shows a new pairing code. Throws [StateError] while remote access is
  /// off — the dialog says so instead of pretending.
  Future<HostPairingSession> beginPairing({
    required CapabilitySet capabilities,
  }) {
    final service = _service;
    if (service == null || !service.isRunning) {
      throw StateError('Turn on remote access first.');
    }
    return service.beginPairing(capabilities: capabilities);
  }

  Future<void> cancelPairing() async {
    await _service?.cancelPairing();
  }

  /// Revokes a device: key deleted, frames rejected. Works with the service
  /// off too — a revocation must never wait for a listener.
  Future<void> revoke(PairedDevice device) async {
    final service = _service;
    if (service != null) {
      await service.revoke(device.id);
    } else {
      _ref.read(pairedDeviceDaoProvider).revoke(device.id);
    }
    _ref.read(pairedDevicesRevisionProvider.notifier).bump();
  }

  /// The lifecycle teardown: stop listening, close every channel.
  Future<void> shutdown() {
    _chain = _chain.then((_) => _stopService()).catchError((Object _) {});
    return _chain;
  }

  // --- Event fan-out, wired by the provider below ---------------------------

  void onSessionsMoved() {
    final service = _service;
    if (service == null) return;
    unawaited(service.notifySessionsChanged());
  }

  void onAttention(
    List<SessionAttention>? previous,
    List<SessionAttention> next,
  ) {
    final service = _service;
    if (service == null) return;
    unawaited(service.notifySessionsChanged());
    final before = {
      for (final attention in previous ?? const <SessionAttention>[])
        if (attention.kind == AttentionKind.needsInput)
          attention.session.openId,
    };
    for (final attention in next) {
      if (attention.kind != AttentionKind.needsInput) continue;
      if (attention.session.imported) continue;
      if (before.contains(attention.session.openId)) continue;
      unawaited(service.notifyApprovalRequested(attention.session.openId));
    }
  }

  /// New attention-inbox items — the same finished / needs-you / failed
  /// policy the tray reads — become sealed pushes for paired phones with no
  /// live link. Connected phones already heard it as `session.changed`.
  void onInboxChanged(AttentionInbox? previous, AttentionInbox next) {
    final service = _service;
    if (service == null) return;
    final before = {
      for (final item in previous?.items ?? const <InboxItem>[]) item.id,
    };
    for (final item in next.items) {
      if (before.contains(item.id)) continue;
      if (item.session.imported) continue;
      final kind = switch (item.kind) {
        InboxItemKind.finished => 'finished',
        InboxItemKind.needsApproval => 'needs_approval',
        InboxItemKind.failed => 'failed',
        // Delivery news (checks, reviews, merges) stays on the desktop in v1.
        InboxItemKind.checksFailed ||
        InboxItemKind.changesRequested ||
        InboxItemKind.readyToMerge => null,
      };
      if (kind == null) continue;
      unawaited(
        service.pushAttentionNews(
          sessionId: item.session.openId,
          title: item.session.label,
          kind: kind,
        ),
      );
    }
  }
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
  ref.onDispose(() {
    unawaited(controller.shutdown());
  });
  // Bring the service up if the user had it enabled last run.
  unawaited(controller.sync());
  return controller;
});
