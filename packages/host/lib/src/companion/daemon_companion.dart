import 'dart:async';

import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/push.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';

import '../domain/session_registry.dart';
import '../protocol/messages.dart';
import 'companion_app_relay.dart';
import 'companion_handler.dart';
import 'registry_screens.dart';

/// The phone companion, served by the daemon: the one companion server on a
/// machine with a session host, running whether or not the desktop app is.
///
/// It runs `RemoteHostService` — pairing, sealed channels, the LAN listener and
/// beacon, relay listeners, push — on the shared store's paired devices, with
/// the bindings `hostCompanionBindings` composes: the store and this host's own
/// screens while no app is connected, and calls forwarded to the app while one
/// is. How it serves is the desktop's Remote access settings, sent by the app
/// on each link and kept in the store for when it is closed.
class DaemonCompanion implements CompanionHandler {
  DaemonCompanion({
    required this.database,
    required this.registry,
    required this.hostName,
    this.lanPort = kHostCompanionPort,
    this.transcriptPollInterval = const Duration(seconds: 2),
    RelayTransportFactory? relayFactory,
    PushPost? pushPost,
    CompanionScreens? screens,
    this.onLog,
    DateTime Function()? clock,
  }) : _relayFactory = relayFactory,
       _pushPost = pushPost,
       _now = clock ?? DateTime.now,
       _devices = PairedDeviceDao(database),
       _configs = CompanionConfigStore(database),
       _sessions = SessionDao(database),
       screens = screens ?? RegistryScreens(registry);

  final AppDatabase database;
  final SessionRegistry registry;
  final String hostName;

  /// Where the LAN listener binds first; another port when it is taken, which
  /// the beacon and `host.status` carry.
  final int lanPort;
  final Duration transcriptPollInterval;
  final CompanionScreens screens;

  /// Lifecycle only — never a code, a key or a payload.
  final void Function(String message)? onLog;

  final RelayTransportFactory? _relayFactory;
  final PushPost? _pushPost;
  final DateTime Function() _now;
  final PairedDeviceDao _devices;
  final CompanionConfigStore _configs;
  final SessionDao _sessions;

  /// The desktop app companion calls are forwarded to, while one is connected.
  final CompanionAppRelay app = CompanionAppRelay();

  late final RemoteHostBindings bindings = hostCompanionBindings(
    hostName: hostName,
    app: app,
    atRest: SessionsAtRest(
      sessions: _sessions,
      names: WorkspaceNames(database),
      screens: screens,
      hostName: hostName,
      clock: _now,
    ),
    notes: () async => notesSnapshot(
      notes: NoteDao(database),
      todos: TodoDao(database),
      projectNames: WorkspaceNames(database).projects(),
      notesEnabled: _config.notesEnabled,
    ),
    registerPush: (deviceId, token, platform, presence) async {
      _devices.updatePush(
        deviceId,
        token: token,
        platform: platform,
        presence: presence,
        now: _now().toUtc(),
      );
      _devicesChanged();
    },
  );

  CompanionConfig _config = CompanionConfig.unconfigured;
  RemoteHostService? _service;
  void Function(HostMessage)? _appSend;
  Future<void> _chain = Future<void>.value();
  StreamSubscription<LifecycleEvent>? _events;

  /// The running server, or null while remote access is off.
  RemoteHostService? get service => _service;

  /// What it is serving by now.
  CompanionConfig get config => _config;

  /// Where the LAN listener bound, while serving.
  int? get port => _service?.lanPortBound;

  int paired() => _devices.getActive().length;

  /// Serves by the config the store kept, or a box's defaults when no app has
  /// ever sent one, following [sessionEvents] — the host's lifecycle feed.
  /// Throws when the LAN listener cannot bind at all.
  Future<void> start({required Stream<LifecycleEvent> sessionEvents}) async {
    app.onChanged = (_) => _sessionsMoved();
    _events = sessionEvents.listen(_onLifecycle);
    await _serialised(() => _apply(_configs.read() ?? _config));
  }

  @override
  Future<CompanionPairingWindow> openPairing({
    required int capabilities,
    required String relay,
    required bool relayIsLocal,
  }) async {
    final service = _service;
    if (service == null || !service.isRunning) {
      throw StateError('remote access is switched off on this machine');
    }
    final named = relay.trim();
    final via = named.isEmpty ? null : _usableRelay(named);
    if (named.isNotEmpty && via == null) {
      throw FormatException('"$relay" is not a relay this host can dial');
    }
    final session = await service.beginPairing(
      capabilities: CapabilitySet(capabilities),
      relay: via,
      relayIsLocal: relayIsLocal,
    );
    return (
      code: PairingCode.encode(session.payload.typedSecret!),
      expiresAt: session.deadline,
      payload: session.payload.encode(),
      paired: session.done.then((device) => device.id),
    );
  }

  @override
  Future<void> adopt(
    Object owner,
    Map<String, Object?> config,
    void Function(HostMessage) send,
  ) {
    final next = CompanionConfig.fromJson(config);
    _configs.write(next);
    _appSend = send;
    app.adopt(owner, send);
    return _serialised(() => _apply(next));
  }

  @override
  void answer(Object owner, CompanionResultMessage result) =>
      app.answer(owner, result);

  @override
  Future<void> notice(Object owner, CompanionNoticeMessage notice) async {
    final service = _service;
    if (service == null) return;
    switch (notice.kind) {
      case CompanionNoticeKind.sessionsMoved:
        await service.notifySessionsChanged();
      case CompanionNoticeKind.approvalRequested:
        final sessionId = notice.sessionId;
        if (sessionId != null) await service.notifyApprovalRequested(sessionId);
      case CompanionNoticeKind.attention:
        final sessionId = notice.sessionId;
        final kind = notice.attention;
        if (sessionId == null || kind == null) return;
        await service.pushAttentionNews(
          sessionId: sessionId,
          title: notice.title ?? '',
          kind: kind,
          detail: notice.detail,
        );
      case CompanionNoticeKind.devicesChanged:
        await service.reconcileDevices();
      case CompanionNoticeKind.pairingCancelled:
        await service.cancelPairing();
    }
  }

  @override
  Future<void> detach(Object owner) async {
    final wasApp = app.isApp(owner);
    app.detach(owner);
    if (!wasApp) return;
    _appSend = null;
    // The app's embedded relay closed with it; nothing waits there any more.
    if (_config.localRelayUrl != null) {
      await _serialised(() => _apply(_config.withoutLocalRelay()));
    }
  }

  Future<void> close() async {
    await _events?.cancel();
    _events = null;
    app.onChanged = null;
    app.close();
    await _serialised(_stopService);
  }

  Future<void> _serialised(Future<void> Function() step) {
    final next = _chain.then((_) => step());
    _chain = next.catchError((Object error) {
      onLog?.call('the companion could not be brought in line: $error');
    });
    return next;
  }

  Future<void> _apply(CompanionConfig next) async {
    final previous = _config;
    _config = next;
    if (!next.enabled) {
      await _stopService();
      return;
    }
    final running = _service;
    if (running != null && !previous.restartsFor(next)) {
      await running.updateRelays(
        localRelayUrl: next.localRelayUrl,
        hostedEnabled: next.hostedEnabled,
        extraRelays: next.extraRelays,
      );
      return;
    }
    await _stopService();
    final started = RemoteHostService(
      devices: _devices,
      hostId: hostDeviceIdFor(database),
      bindings: bindings,
      relay: next.relay,
      localRelayUrl: next.localRelayUrl,
      hostedEnabled: next.hostedEnabled,
      extraRelays: next.extraRelays,
      lanPort: lanPort,
      advertise: next.advertise,
      transcriptPollInterval: transcriptPollInterval,
      now: _now,
      relayFactory: _relayFactory,
      pushPost: _pushPost,
      onDevicesChanged: _devicesChanged,
      onLog: onLog,
    );
    _service = started;
    await started.start();
  }

  Future<void> _stopService() async {
    final service = _service;
    _service = null;
    await service?.stop();
  }

  void _devicesChanged() => _appSend?.call(
    const CompanionEventMessage(CompanionEventKind.devicesChanged),
  );

  void _sessionsMoved() {
    final service = _service;
    if (service != null) unawaited(service.notifySessionsChanged());
  }

  /// A session this host runs started or ended: live phones re-read, and —
  /// with no app to file an inbox item — a phone with no live link is pushed
  /// the ending, as the app's inbox would have.
  void _onLifecycle(LifecycleEvent event) {
    // After the status recording, which listens on the same synchronous feed
    // and writes the row this change is read from.
    scheduleMicrotask(() {
      _sessionsMoved();
      if (event.kind == LifecycleEventKind.exited && !app.connected) {
        unawaited(_pushEnding(event));
      }
    });
  }

  Future<void> _pushEnding(LifecycleEvent event) async {
    final service = _service;
    final code = event.exitCode;
    // Ended by request, or with no code to judge by: nothing to announce.
    if (service == null || event.endedByClose || code == null) return;
    final rows = _sessions.getAll();
    final rowId = sessionIdForHostId(event.sessionId, [
      for (final row in rows) row.id,
    ]);
    final row = rowId == null
        ? null
        : rows.firstWhere((candidate) => candidate.id == rowId);
    await service.pushAttentionNews(
      sessionId: rowId ?? event.sessionId,
      title:
          row?.title ??
          screens.find(event.sessionId)?.command ??
          event.sessionId,
      kind: code == 0 ? 'finished' : 'failed',
    );
  }

  /// The relay a pairing names, or null when it names none this host can
  /// dial. [kLocalRelayMarker] is a word for the app's own relay, not a URL.
  static Uri? _usableRelay(String url) {
    if (url == kLocalRelayMarker) return null;
    final parsed = Uri.tryParse(url);
    if (parsed == null || parsed.host.isEmpty) return null;
    return switch (parsed.scheme) {
      'ws' || 'wss' || 'http' || 'https' => parsed,
      _ => null,
    };
  }
}
