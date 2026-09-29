import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_host_protocol/protocol.dart' show kProtocolVersion;
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart'
    show CapabilitySet, kHostLinkResumeGrace;
import 'package:karmashala_terminal_runtime/host_link.dart'
    show SharedHostLinks;

/// The `welcome.features` entry a server announces when it keeps a dropped
/// desktop link for a resume (`server/lib/src/serve/server_features.dart`).
const String kLinkResumeFeature = 'link.resume';

/// Announced when the server takes a resume onto a second socket while the
/// first still carries the link, so a desktop on a relay can move to the LAN
/// make-before-break (Stage 0 step 18).
const String kLinkPromoteFeature = 'link.promote';

/// Announced when the server answers an empty frame on a switched link, so an
/// idle desktop can find a half-open socket (Stage 0 step 18).
const String kLinkKeepaliveFeature = 'link.keepalive';

/// A Karmashala server on another machine (slice 5e), reached the way the
/// phone reaches one — its LAN listener, a beacon sighting, its announced LAN
/// address or a relay, the sealed channel — and switched to the host
/// protocol. Nothing is started or supervised: it is only dialled.
///
/// Owns the process's one [LanPathScout] while this machine is in use: it
/// starts listening for beacons here, so sightings have gathered by the first
/// dial, and stops at [close]. The local server never builds one of these, so
/// the scout never runs for it.
class RemoteServerAccess implements HostSessionAccess {
  RemoteServerAccess({
    required this.hostId,
    required this.hostName,
    required this.store,
    DesktopServerDialer? dialer,
    MulticastLockHolder? lanLock,
    AppLogger? logger,
    void Function(String message)? onLog,
  }) : _dialer =
           dialer ??
           DesktopServerDialer(
             store: store,
             // Android hears no beacon without the OS multicast lock held.
             scout: LanPathScout(lock: lanLock, onLog: onLog ?? _defaultLog),
             onLog: onLog ?? _defaultLog,
           ),
       _log = logger ?? AppLogger.named('remote') {
    unawaited(_dialer.startScouting());
  }

  final String hostId;
  final String hostName;

  /// Where the pairing record lives; read on every dial, since each dial
  /// moves its generation on and may learn new routes.
  final CompanionStore store;
  final DesktopServerDialer _dialer;
  final AppLogger _log;

  final ValueNotifier<CapabilitySet?> _grants = ValueNotifier(null);

  /// What the server granted this desktop in the last link's `host.status`;
  /// null before the first link. A grant edited on the server reaches this
  /// only when the link is next dialled.
  ValueListenable<CapabilitySet?> get grants => _grants;

  final ValueNotifier<bool> _resuming = ValueNotifier(false);

  /// True while the link's socket is down and it is held for a resume
  /// (Stage 0 step 17): what was open stays open, and nothing has ended yet.
  ValueListenable<bool> get resuming => _resuming;

  static final AppLogger _dialLog = AppLogger.named('remote_dial');
  static void _defaultLog(String message) => _dialLog.info(message);

  @override
  String get address => hostName;

  @override
  Stream<void> get reconnected => const Stream<void>.empty();

  /// Always "ready": whether it answers is what [exec] finds out.
  @override
  Future<HostDeployment> deployment() async => HostDeployment(
    status: HostDeploymentStatus.ready,
    observedAt: DateTime.now().toUtc(),
    reason: 'a server on another machine, dialled over the sealed channel',
    remotePath: 'karmashala_host',
    protocolVersion: kProtocolVersion,
  );

  @override
  Future<RemoteChannel> exec(String command) async {
    // Hung up in the background: every redial waits here for the app to
    // come back, rather than waking the phone to dial every few seconds.
    final resting = _resting;
    if (resting != null) await resting.future;
    if (_closed) {
      throw HostLinkException('$hostName is no longer the machine in use.');
    }
    final record = (await CompanionConnections.load(store)).byHost(hostId);
    if (record == null) {
      throw HostLinkException('$hostName is no longer paired with this app.');
    }
    try {
      final link = await _dialer.dial(
        record,
        // Stage 0 step 17: a dropped socket is resumed, not redialled, when
        // this link's server said `link.resume` in its welcome — asked at the
        // drop, since the welcome comes after the dial.
        resumeOffered: () =>
            SharedHostLinks.current(
              this,
            )?.welcome.features.contains(kLinkResumeFeature) ??
            false,
        onHeld: (held) => _resuming.value = held,
        // Stage 0 step 18: relay→LAN promotion over a resume, and pings on
        // an idle link — each only where the server announced it.
        promoteOffered: () => _offers(kLinkPromoteFeature),
        keepaliveOffered: () => _offers(kLinkKeepaliveFeature),
      );
      _grants.value = link.capabilities;
      _log.info(
        'Linked to $hostName; grants=['
        '${link.capabilities.granted.map((c) => c.wire).join(',')}].',
      );
      return SealedHostChannel(link);
    } on DesktopConnectException catch (error) {
      throw HostLinkException(error.message);
    }
  }

  /// Whether this server's welcome, on the shared link, names [feature].
  bool _offers(String feature) =>
      SharedHostLinks.current(this)?.welcome.features.contains(feature) ??
      false;

  var _closed = false;
  var _background = false;
  Timer? _restTimer;

  /// Set while the link is hung up in the background; completed by [wake].
  Completer<void>? _resting;

  /// The app went to the background (a phone; owner's answer 6 of the
  /// Stage 1 plan): the beacon stops at once, the link is held for
  /// [kBackgroundLinkGrace] so a quick return finds it live, then hung up,
  /// and nothing is dialled again until [wake].
  void rest() {
    if (_closed || _background) return;
    _background = true;
    unawaited(_dialer.pauseScouting());
    _restTimer = Timer(kBackgroundLinkGrace, () {
      _restTimer = null;
      if (_closed || !_background) return;
      _resting = Completer<void>();
      _log.info(
        'In the background for ${kBackgroundLinkGrace.inSeconds}s; hanging '
        'up the link to $hostName until the app returns.',
      );
      unawaited(SharedHostLinks.drop(this));
    });
  }

  /// Back in front: the beacon is listened for afresh, dials go through
  /// again, and a link still up proves itself rather than being trusted.
  void wake() {
    if (_closed) return;
    final wasBackground = _background;
    _background = false;
    _restTimer?.cancel();
    _restTimer = null;
    final resting = _resting;
    _resting = null;
    if (resting != null && !resting.isCompleted) resting.complete();
    if (wasBackground) unawaited(_dialer.restartScouting());
    _dialer.proveLinks();
  }

  /// The device's network changed (Wi-Fi to mobile, a new Wi-Fi): the socket
  /// under the link may be dead, and the beacon group was joined on
  /// interfaces that may be gone. Hung up in the background, [wake] does it.
  void networkChanged() {
    if (_closed || _resting != null) return;
    if (!_background) unawaited(_dialer.restartScouting());
    _dialer.proveLinks();
  }

  /// This machine is no longer in use: beacon listening stops. Links already
  /// open are their owners' to close. Today a switch relaunches the app, so
  /// the process ending does this; step 13's per-server `close()` calls it.
  Future<void> close() {
    _closed = true;
    _restTimer?.cancel();
    _restTimer = null;
    final resting = _resting;
    _resting = null;
    if (resting != null && !resting.isCompleted) resting.complete();
    return _dialer.close();
  }
}

/// How long a phone in the background keeps its link: the server's resume
/// grace, so a return within it resumes rather than redials.
const Duration kBackgroundLinkGrace = kHostLinkResumeGrace;
