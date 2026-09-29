/// A desktop app as the client of a server on another machine (slice 5e):
/// the phone's pairing record and sealed channel, switched to the host
/// protocol with `host.attach`, over the server's LAN listener or a relay.
library;

import 'dart:async';
import 'dart:io' show InternetAddress;
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:karmashala_host_protocol/host_access.dart' show RemoteChannel;

import '../domain/remote_payloads.dart' show RemoteHostStatus;
import '../pairing/pairing_wire.dart';
import '../protocol.dart';
import '../transport/key_schedule.dart';
import '../transport/lan_beacon.dart' show DiscoveredHost, LanAdvert;
import '../transport/lan_transport.dart';
import '../transport/relay_transport.dart';
import '../transport/remote_transport.dart';
import '../transport/sealed_channel.dart';
import '../transport/sealed_host_link.dart';
import 'companion_client.dart'
    show RelayTransportFactoryFn, kCompanionProbeWindow;
import 'companion_store.dart';
import 'lan_path.dart' show LanDialerFn, LanPathScout;
import 'relay_candidates.dart';
import 'route_pin.dart';

/// Why a desktop could not reach its server; [message] is safe to show.
class DesktopConnectException implements Exception {
  const DesktopConnectException(this.message, {this.refused = false});

  final String message;

  /// The server answered and said no (the pairing grants no desktop): no
  /// other route or generation will say otherwise.
  final bool refused;

  @override
  String toString() => message;
}

/// How a switched link comes back after its socket drops (Stage 0 step 17),
/// instead of ending: the server keeps it for [grace] (`link.resume`, step
/// 16), and the link is resumed over whichever of [routes] answers first.
class DesktopLinkResume {
  const DesktopLinkResume({
    required this.offered,
    required this.routes,
    this.hostName = 'the server',
    this.grace = kHostLinkResumeGrace,
    this.onLog,
    this.onHeld,
  });

  /// Hears true when the link is held for a resume, and false once it is
  /// back or has ended — for a "Reconnecting…" banner.
  final void Function(bool held)? onHeld;

  /// Asked at the drop: whether the server announced `link.resume` in its
  /// welcome. False — an older server, or a link that never said hello —
  /// ends the link at once, as before a resume existed.
  final bool Function() offered;

  /// The routes to try for the link's generation, best first; asked afresh
  /// for each pass, so a sighting or relay learned meanwhile is in it.
  final Future<List<DesktopResumeRoute>> Function(int generation) routes;

  final String hostName;

  /// The heal timer: the one place that gives up. When it fires the link
  /// ends, and the owners above it redial as they always did.
  final Duration grace;

  /// One line when a link is suspended, and one per outcome.
  final void Function(String message)? onLog;
}

/// One way back to the server for a resume.
class DesktopResumeRoute {
  const DesktopResumeRoute({
    required this.path,
    required this.label,
    required this.timeout,
    required this.open,
    this.noted,
  });

  /// `direct`, `lan`, `relay`… for the log.
  final String path;

  /// Where, safe to log.
  final String label;

  /// How long connecting and the resume's answer may take together.
  final Duration timeout;

  final Future<RemoteTransport> Function() open;

  /// Hears whether the server answered here, for route health.
  final void Function(bool answered)? noted;
}

/// The heal loop's waits between passes over every route.
const List<Duration> kDesktopResumeDelays = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 5),
];

/// Opens one sealed host link over [transport] at [generation]: the link
/// hello, the server's `host.status`, then `host.attach`. The transport is
/// closed with the link. The link's `capabilities` are what that status
/// granted, as of this link only.
///
/// A transport that drops ends the link — unless [resume] is given and the
/// server offers `link.resume`: then the link is held (writes wait in its
/// retain window), and a heal loop resumes it over [DesktopLinkResume.routes]
/// within the grace. Whoever reads the link sees a stall, not an end. On a
/// refusal, the grace running out or a server that offers no resume, the
/// link ends as it always did.
///
/// [onHostStatus] hears the server's `host.status` — where it can be met
/// (relays, LAN address) — for the dialer to fold into the saved record.
Future<SealedHostLink> connectDesktopLink({
  required CompanionPairing pairing,
  required RemoteTransport transport,
  required int generation,
  Duration timeout = const Duration(seconds: 8),
  void Function(RemoteHostStatus status)? onHostStatus,
  DesktopLinkResume? resume,
}) async {
  final key = SecretKeyData(pairing.deviceKey);
  final channel = await SealedChannel.forDevice(
    deviceKey: key,
    role: ChannelRole.companion,
    generation: generation,
  );
  // An older server's status carries no grants: the pairing's stand in.
  var granted = pairing.capabilities;
  final greeted = Completer<void>();
  final attached = Completer<void>();
  final rendezvous = await rendezvousFor(key, generation);
  late final _DesktopLinkKeeper keeper;
  keeper = _DesktopLinkKeeper(
    channel: channel,
    rendezvous: rendezvous,
    generation: generation,
    resume: resume,
    onEnvelope: (envelope, opened) {
      switch (envelope.knownType) {
        case FrameType.hostStatus when !greeted.isCompleted:
          try {
            final caps = RemoteHostStatus.fromJson(
              envelope.payload,
            ).capabilities;
            if (caps != null) granted = caps;
          } on Object {
            // A status this build cannot read still greets.
          }
          _hearHostStatus(envelope.payload, onHostStatus);
          greeted.complete();
        case FrameType.result when envelope.id == _attachId:
          keeper.link = SealedHostLink(
            channel: channel,
            sendSealed: keeper.sendSealed,
            nextReceiveSequence: opened.sequence + 1,
            capabilities: granted,
            // Kept for a resume only where one can be asked for.
            retainForResume: resume != null,
          );
          if (!attached.isCompleted) attached.complete();
        case FrameType.error when envelope.id == _attachId:
          final message = envelope.payload['message'];
          if (!attached.isCompleted) {
            attached.completeError(
              DesktopConnectException(
                message is String ? message : 'the server refused',
                refused: true,
              ),
            );
          }
        default:
          break;
      }
    },
  );
  keeper.adopt(transport);

  Future<SealedHostLink> give(Object error) async {
    await keeper.release();
    throw error;
  }

  try {
    transport.send(LinkHello(rendezvous).encode());
    await greeted.future.timeout(timeout);
    final envelope = Envelope.of(
      FrameType.hostAttach,
      seq: channel.nextSendSequence,
      id: _attachId,
    );
    transport.send(await channel.seal(envelope.toBytes()));
    await attached.future.timeout(timeout);
  } on TimeoutException {
    return give(
      DesktopConnectException(
        keeper.everConnected
            ? 'the server did not answer there'
            : 'nothing could be reached there',
      ),
    );
  } on DesktopConnectException catch (error) {
    return give(error);
  } on TransportException catch (error) {
    return give(DesktopConnectException(error.message));
  }
  final opened = keeper.link!;
  unawaited(opened.done.then((_) => keeper.release()));
  return opened;
}

const String _attachId = 'attach';

/// Owns a desktop link's socket — first the one it was opened on, then any
/// it was resumed over — and the heal loop between them.
class _DesktopLinkKeeper {
  _DesktopLinkKeeper({
    required this.channel,
    required this.rendezvous,
    required this.generation,
    required this.resume,
    required this.onEnvelope,
  });

  final SealedChannel channel;
  final RendezvousId rendezvous;
  final int generation;
  final DesktopLinkResume? resume;

  /// Frames before the link exists: the switch's envelopes.
  final void Function(Envelope envelope, SealedFrame opened) onEnvelope;

  SealedHostLink? link;

  /// Whether the first socket ever connected, for the dial's error text.
  bool everConnected = false;

  RemoteTransport? _transport;
  StreamSubscription<Uint8List>? _frames;
  StreamSubscription<TransportState>? _states;
  Future<void> _chain = Future<void>.value();

  /// The resume in flight on [_transport], if any.
  _ResumeAttempt? _attempt;
  Timer? _heal;
  var _attempts = 0;

  /// Whether this suspension's outcome has been logged: once each.
  var _told = true;
  var _released = false;

  /// The link's way out: whichever socket it is on now. While the link is
  /// suspended it hands nothing here; a resume sends through the new one.
  void sendSealed(Uint8List sealed) {
    final transport = _transport;
    if (transport == null) {
      throw const TransportException('the link has no connection');
    }
    transport.send(sealed);
  }

  /// Makes [transport] the link's socket, reading its frames and drops.
  void adopt(RemoteTransport transport) {
    _transport = transport;
    var connected = false;
    _frames = transport.frames.listen((frame) {
      _chain = _chain.then((_) => _onFrame(transport, frame));
    });
    _states = transport.states.listen((state) {
      if (!identical(_transport, transport)) return;
      if (state == TransportState.connected) {
        connected = true;
        everConnected = true;
        _attempt?.connected();
        return;
      }
      if (state != TransportState.disconnected &&
          state != TransportState.closed) {
        return;
      }
      final attempt = _attempt;
      if (attempt != null) {
        attempt.fail(
          connected ? 'the connection dropped' : 'nothing could be reached',
        );
        return;
      }
      if (connected) _dropped();
    });
  }

  /// Lets go of the current socket, and closes it.
  Future<void> _detach({bool discard = false}) async {
    final transport = _transport;
    final frames = _frames;
    final states = _states;
    _transport = null;
    _frames = null;
    _states = null;
    // Frames it queued while down are in the link's retain window too; a
    // stale flush must never go out anywhere (step 16's contract).
    if (discard && transport is ReconnectingTransport) {
      transport.discardQueued();
    }
    await frames?.cancel();
    await states?.cancel();
    try {
      await transport?.close();
    } on Object {
      // Already gone.
    }
  }

  /// The link is over: nothing more is dialled, and its socket closes.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    _heal?.cancel();
    final current = link;
    if (current != null && current.suspended) {
      // Ended while held some other way: the window overflowed, too many
      // resumes, an answer that could not be taken, or its owner hung up.
      _tell(
        'link to ${resume?.hostName ?? 'the server'} could not be resumed '
        '(${current.closeReason}); redialling',
      );
    }
    _attempt?.fail('the link ended');
    await _detach();
  }

  Future<void> _onFrame(RemoteTransport transport, Uint8List frame) async {
    // A socket given up on: whatever it still carries is not read.
    if (!identical(_transport, transport)) return;
    final attempt = _attempt;
    final SealedFrame opened;
    try {
      opened = await channel.unseal(frame);
    } on SealedChannelException catch (error) {
      if (attempt != null) {
        attempt.fail('a frame would not open: $error');
      } else {
        link?.close('a frame would not open: $error');
      }
      return;
    }
    if (attempt != null) {
      await _onResumeAnswer(attempt, transport, opened);
      return;
    }
    final current = link;
    if (current != null) {
      current.receive(opened);
      return;
    }
    final Envelope envelope;
    try {
      envelope = Envelope.fromBytes(opened.plaintext, accept: VersionRange.any);
    } on ProtocolException {
      return;
    }
    onEnvelope(envelope, opened);
  }

  /// The socket under a live link dropped: hold the link for a resume when
  /// the server offers one, or end it as before.
  void _dropped() {
    final current = link;
    if (current == null || current.isClosed || current.suspended) return;
    final resume = this.resume;
    if (resume == null || !current.retainForResume) {
      current.close('the connection dropped');
      return;
    }
    bool offered;
    try {
      offered = resume.offered();
    } on Object {
      offered = false;
    }
    if (!offered) {
      resume.onLog?.call(
        'link to ${resume.hostName} dropped; the server offers no resume, '
        'redialling',
      );
      current.close('the connection dropped');
      return;
    }
    current.suspend();
    _told = false;
    unawaited(_detach(discard: true));
    resume.onLog?.call(
      'link to ${resume.hostName} dropped; resuming it within '
      '${resume.grace.inSeconds}s',
    );
    resume.onHeld?.call(true);
    // The heal timer always fires: it is the one place that gives up.
    _heal = Timer(resume.grace, () {
      _tell(
        'link to ${resume.hostName} not resumed within '
        '${resume.grace.inSeconds}s; retired, redialling',
      );
      current.close('not resumed within the grace');
    });
    unawaited(_healLoop(current, resume));
  }

  Future<void> _healLoop(SealedHostLink current, DesktopLinkResume resume) async {
    var pass = 0;
    bool waiting() => !current.isClosed && current.suspended && !_released;
    while (waiting()) {
      List<DesktopResumeRoute> routes;
      try {
        routes = await resume.routes(generation);
      } on Object {
        routes = const [];
      }
      for (final route in routes) {
        if (!waiting()) return;
        final outcome = await _tryRoute(current, route);
        if (outcome == null) {
          _heal?.cancel();
          _tell(
            'resumed link to ${resume.hostName} over ${route.path} at '
            '${route.label} (generation $generation)',
          );
          return;
        }
        if (outcome.refused) {
          _heal?.cancel();
          _tell(
            '${resume.hostName} refused the resume (${outcome.reason}); '
            'redialling',
          );
          current.close('the server refused the resume: ${outcome.reason}');
          return;
        }
      }
      if (!waiting()) return;
      final wait =
          kDesktopResumeDelays[pass < kDesktopResumeDelays.length
              ? pass
              : kDesktopResumeDelays.length - 1];
      pass++;
      await Future.any<void>([
        Future<void>.delayed(wait),
        current.done,
      ]);
    }
  }

  /// Says this suspension's outcome, once, and that the link is no longer
  /// held.
  void _tell(String message) {
    if (_told) return;
    _told = true;
    resume?.onLog?.call(message);
    resume?.onHeld?.call(false);
  }

  /// One resume over [route]. Null when the link is back; otherwise why not.
  Future<({bool refused, String reason})?> _tryRoute(
    SealedHostLink current,
    DesktopResumeRoute route,
  ) async {
    final RemoteTransport transport;
    try {
      transport = await route.open();
    } on Object catch (error) {
      route.noted?.call(false);
      return (refused: false, reason: '$error');
    }
    if (current.isClosed || _released) {
      await transport.close();
      return (refused: false, reason: 'the link ended');
    }
    final attempt = _ResumeAttempt('resume-${++_attempts}');
    _attempt = attempt;
    adopt(transport);
    final deadline = Timer(route.timeout, () {
      attempt.fail(
        attempt.isConnected
            ? 'the server did not answer there'
            : 'nothing could be reached there',
      );
    });
    // Sealed only once the socket is up: a resume frame takes a sequence the
    // server must step over, so one that could never go out is not spent.
    unawaited(
      attempt.whenConnected.then((_) async {
        if (attempt.isOver || !identical(_transport, transport)) return;
        try {
          transport.send(LinkHello(rendezvous, resume: true).encode());
        } on TransportException catch (error) {
          attempt.fail(error.message);
          return;
        }
        final sealed = await current.sealResume(
          (sequence, lastReceived, skip) => Envelope.of(
            FrameType.linkResume,
            seq: sequence,
            id: attempt.id,
            payload: {'lastReceived': lastReceived, 'skip': skip},
          ).toBytes(),
        );
        if (sealed == null) {
          attempt.fail(current.closeReason ?? 'the link ended');
          return;
        }
        if (attempt.isOver || !identical(_transport, transport)) return;
        try {
          transport.send(sealed);
        } on TransportException catch (error) {
          attempt.fail(error.message);
        }
      }),
    );
    final outcome = await attempt.outcome;
    deadline.cancel();
    if (identical(_attempt, attempt)) _attempt = null;
    if (outcome == null) {
      route.noted?.call(true);
      return null;
    }
    route.noted?.call(outcome.refused);
    if (identical(_transport, transport)) await _detach(discard: true);
    return outcome;
  }

  /// The first frame on a resuming socket: the server's answer.
  Future<void> _onResumeAnswer(
    _ResumeAttempt attempt,
    RemoteTransport transport,
    SealedFrame opened,
  ) async {
    // Given up on while the frame was being opened: that socket is gone.
    if (attempt.isOver || !identical(_transport, transport)) return;
    final current = link;
    Envelope? envelope;
    try {
      envelope = Envelope.fromBytes(opened.plaintext, accept: VersionRange.any);
    } on ProtocolException {
      envelope = null;
    }
    if (current == null || envelope == null || envelope.id != attempt.id) {
      attempt.fail('the server answered something other than the resume');
      return;
    }
    if (envelope.knownType == FrameType.error) {
      final message = envelope.payload['message'];
      attempt.refuse(message is String ? message : 'refused');
      return;
    }
    final payload = envelope.payload;
    final last = payload['lastReceived'];
    final skip = payload['skip'];
    if (envelope.knownType != FrameType.result ||
        payload['resumed'] != true ||
        last is! int) {
      attempt.fail('the server\'s answer could not be read');
      return;
    }
    // Taken: from here the deadline no longer applies, and the frames after
    // this one are the link's own.
    attempt.answered();
    _attempt = null;
    final resumed = await current.completeResume(
      peerLastReceived: last,
      peerAnswerSequence: opened.sequence,
      peerSkip: [
        if (skip is List)
          for (final s in skip.take(kHostLinkMaxResumeFrames))
            if (s is int) s,
      ],
    );
    if (resumed) {
      attempt.succeed();
    } else {
      attempt.refuse(current.closeReason ?? 'the answer could not be taken');
    }
  }
}

/// One `link.resume` over one socket.
class _ResumeAttempt {
  _ResumeAttempt(this.id);

  final String id;
  final _connected = Completer<void>();
  final _outcome = Completer<({bool refused, String reason})?>();
  var _answered = false;

  bool get isConnected => _connected.isCompleted;
  bool get isOver => _outcome.isCompleted;
  Future<void> get whenConnected => _connected.future;
  Future<({bool refused, String reason})?> get outcome => _outcome.future;

  void connected() {
    if (!_connected.isCompleted) _connected.complete();
  }

  /// The answer arrived: nothing but its own outcome ends this attempt now.
  void answered() => _answered = true;

  void succeed() {
    if (!_outcome.isCompleted) _outcome.complete(null);
  }

  void refuse(String reason) {
    if (!_outcome.isCompleted) {
      _outcome.complete((refused: true, reason: reason));
    }
  }

  void fail(String reason) {
    if (_answered || _outcome.isCompleted) return;
    _outcome.complete((refused: false, reason: reason));
  }
}

/// Hands [payload] to [listener] decoded. A status this build cannot read
/// costs its routes, never the link.
void _hearHostStatus(
  Map<String, Object?> payload,
  void Function(RemoteHostStatus status)? listener,
) {
  if (listener == null) return;
  final RemoteHostStatus status;
  try {
    status = RemoteHostStatus.fromJson(payload);
  } on ProtocolException {
    return;
  }
  listener(status);
}

/// Dials a paired server in the phone's order
/// (`remote_companion_gateway_dial.dart`), minus the promotion that needs a
/// live link to promote (Stage 0 step 18):
///
/// 1. the address typed at pairing ([CompanionPairing.directEndpoint]);
/// 2. the route pin, when set — a pin is "only", never "prefer";
/// 3. up to three fresh [LanPathScout] sightings;
/// 4. the LAN address the server announced in its last `host.status`;
/// 5. the relays by [orderRelayCandidates] — last known good first, cooling
///    ones skipped — with each outcome stamped on the record.
///
/// Each route walks a few generations forward, but only once something took
/// the socket: nobody home is one dial. The counter moves on after each
/// link, so the next one starts on a fresh generation. The dialer itself
/// does not loop; the data client's and panes' redial delays do.
class DesktopServerDialer {
  DesktopServerDialer({
    required this.store,
    LanDialerFn? lanDialer,
    RelayTransportFactoryFn? relayFactory,
    this.timeout = const Duration(seconds: 6),
    this.lanTimeout = kDesktopLanAttemptTimeout,
    this.scout,
    this.onLog,
    DateTime Function()? now,
  }) : _lanDialer = lanDialer ?? _dialLan,
       _relayFactory = relayFactory ?? _dialRelay,
       _now = now ?? DateTime.now;

  final CompanionStore store;

  /// How long the direct address, a relay or a pinned LAN route may take to
  /// answer the hello and the attach.
  final Duration timeout;

  /// The same for a LAN sighting or hint that is not pinned: a stale advert,
  /// or another server's, must not hold up the relay behind it.
  final Duration lanTimeout;

  /// Beacon listening, owned with this dialer by `RemoteServerAccess`. Null
  /// dials no sightings, as before.
  final LanPathScout? scout;

  final void Function(String message)? onLog;

  final LanDialerFn _lanDialer;
  final RelayTransportFactoryFn _relayFactory;
  final DateTime Function() _now;

  Future<void>? _scoutStarting;
  DateTime? _scoutStartedAt;
  bool _closed = false;

  static RemoteTransport _dialLan(String host, int port) =>
      LanTransport.dial(host: host, port: port);

  static RemoteTransport _dialRelay(Uri relay, RendezvousId rendezvous) =>
      RelayTransport.connect(relay: relay, rendezvous: rendezvous);

  /// Starts beacon listening, once. Called as soon as a remote machine is in
  /// use, so sightings have gathered by the first dial. Never throws: a
  /// network that refuses multicast leaves the scout inert.
  Future<void> startScouting() {
    final scout = this.scout;
    if (scout == null || _closed) return Future<void>.value();
    return _scoutStarting ??= () {
      _scoutStartedAt = _now();
      return scout.start();
    }();
  }

  /// Stops beacon listening for good: this machine is no longer in use.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final starting = _scoutStarting;
    if (starting == null) return;
    await starting;
    await scout?.stop();
  }

  /// Throws [DesktopConnectException] naming what each route answered.
  ///
  /// With [resumeOffered], a link whose socket drops is resumed rather than
  /// ended (Stage 0 step 17) when it answers true at the drop — the server
  /// announced `link.resume`. The resume walks the same routes as this dial,
  /// at the link's own generation, within [kHostLinkResumeGrace].
  Future<SealedHostLink> dial(
    CompanionPairing pairing, {
    bool Function()? resumeOffered,
    void Function(bool held)? onHeld,
  }) async {
    final notes = <String>[];
    final name = pairing.hostName.isEmpty ? 'the server' : pairing.hostName;
    String said() => notes.isEmpty ? '' : ' (${notes.toSet().join('; ')})';
    final resume = resumeOffered == null
        ? null
        : DesktopLinkResume(
            offered: resumeOffered,
            routes: (generation) => _resumeRoutes(pairing, generation),
            hostName: name,
            onLog: onLog,
            onHeld: onHeld,
          );

    // 1. The address typed at pairing: a server with its own address is
    // never worth a detour through a relay.
    final direct = parseEndpoint(pairing.directEndpoint);
    if (direct != null) {
      final link = await _attempt(
        pairing,
        notes,
        label: '${direct.$1}:${direct.$2}',
        path: 'direct',
        timeout: timeout,
        open: (_) async => _lanDialer(direct.$1, direct.$2),
        resume: resume,
      );
      if (link != null) return link;
    }

    // 2. A person's pin: one route and nothing else. A pinned route that
    // does not answer is said, never quietly swapped for another.
    final pin = pairing.pin;
    final pinnedRelay = pin.kind == CompanionRouteKind.relay ? pin.relay : null;
    if (pinnedRelay != null) {
      final link = await _attemptRelay(
        pairing,
        pinnedRelay,
        notes,
        resume: resume,
      );
      if (link != null) return link;
      throw DesktopConnectException(
        '$name is pinned to the relay at ${pinnedRelay.host}, and it is not '
        'answering there${said()}.',
      );
    }
    final pinnedLan = pin.kind == CompanionRouteKind.lan;

    // 3. Fresh beacon sightings. The beacon carries no identity, so one may
    // be another server's: the sealed hello decides, and a wrong one cools
    // down for two minutes.
    final tried = <String>{if (direct != null) '${direct.$1}:${direct.$2}'};
    final scout = this.scout;
    if (scout != null && !_closed) {
      await startScouting();
      await _awaitFirstSighting(scout);
      for (final host in scout.candidates.take(3).toList()) {
        if (!tried.add(scout.keyOf(host))) continue;
        final link = await _attemptLan(
          pairing,
          notes,
          host,
          pinned: pinnedLan,
          resume: resume,
        );
        if (link != null) return link;
      }
    }

    // 4. The LAN address the server announced last time. Unlike the phone,
    // tried even after sightings failed, unless one of them was this very
    // address: another server's beacon on this network (the owner's own, on
    // this PC) must not hide this one's hint.
    final hinted = _lanHintHost(pairing);
    if (hinted != null &&
        tried.add('${hinted.address.address}:${hinted.port}')) {
      // The cooldown exists so a dead address does not delay the relay
      // behind it; a LAN pin has no relay behind it.
      final cooling = !pinnedLan && scout != null && scout.inCooldown(hinted);
      if (!cooling) {
        final link = await _attemptLan(
          pairing,
          notes,
          hinted,
          pinned: pinnedLan,
          resume: resume,
        );
        if (link != null) return link;
      }
    }

    if (pinnedLan) {
      throw DesktopConnectException(
        '$name is pinned to this network (LAN), and it is not answering '
        'here${said()}.',
      );
    }

    // 5. The relays, last known good first.
    for (final url in _relayOrder(pairing)) {
      final link = await _attemptRelay(pairing, url, notes, resume: resume);
      if (link != null) return link;
    }
    throw DesktopConnectException('Could not reach $name${said()}.');
  }

  /// A scout that has only just started has heard nothing yet: give the
  /// first beacon one interval to arrive, once per process, rather than
  /// leaving a server on this network to the relay at every launch.
  Future<void> _awaitFirstSighting(LanPathScout scout) async {
    final started = _scoutStartedAt;
    if (started == null || !scout.isListening) return;
    if (scout.candidates.isNotEmpty) return;
    final left = started.add(kDesktopFirstSightingWait).difference(_now());
    if (left <= Duration.zero) return;
    try {
      await scout.sightings.first.timeout(left);
    } on Object {
      // Nothing heard in time, or the scout stopped: the next route carries on.
    }
  }

  /// The routes a resume walks (Stage 0 step 17), in [dial]'s order and
  /// under its pin, but all at the link's own [generation] — a resume never
  /// probes forward — and without waiting for a first beacon. Read from the
  /// store, so relays and a LAN address learned since the dial are in it.
  Future<List<DesktopResumeRoute>> _resumeRoutes(
    CompanionPairing pairing,
    int generation,
  ) async {
    var saved = pairing;
    try {
      saved =
          (await CompanionConnections.load(store)).byHost(
            pairing.hostId.value,
          ) ??
          pairing;
    } on Object {
      // The record as dialled still names every route it had.
    }
    final key = SecretKeyData(saved.deviceKey);
    final routes = <DesktopResumeRoute>[];
    final direct = parseEndpoint(saved.directEndpoint);
    if (direct != null) {
      routes.add(
        DesktopResumeRoute(
          path: 'direct',
          label: '${direct.$1}:${direct.$2}',
          timeout: timeout,
          open: () async => _lanDialer(direct.$1, direct.$2),
        ),
      );
    }
    DesktopResumeRoute relayRoute(Uri url) => DesktopResumeRoute(
      path: 'relay',
      // The host alone: a relay's URL can carry its access token.
      label: 'relay ${url.host}',
      timeout: timeout,
      open: () async => _relayFactory(url, await rendezvousFor(key, generation)),
      noted: (answered) {
        if (!answered) unawaited(_noteRelayFailure(saved, url));
      },
    );
    final pin = saved.pin;
    final pinnedRelay = pin.kind == CompanionRouteKind.relay ? pin.relay : null;
    if (pinnedRelay != null) return [...routes, relayRoute(pinnedRelay)];
    final pinnedLan = pin.kind == CompanionRouteKind.lan;
    final scout = this.scout;
    DesktopResumeRoute lanRoute(DiscoveredHost host) => DesktopResumeRoute(
      path: host.tag == _kLanHintTag ? 'lan (announced address)' : 'lan',
      label: '${host.address.address}:${host.port}',
      timeout: pinnedLan ? timeout : lanTimeout,
      open: () async => scout != null
          ? scout.dial(host)
          : _lanDialer(host.address.address, host.port),
      noted: scout == null
          ? null
          : (answered) {
              if (answered) {
                scout.noteSuccess(host);
              } else {
                scout.noteFailure(host);
              }
            },
    );
    final tried = <String>{if (direct != null) '${direct.$1}:${direct.$2}'};
    if (scout != null && !_closed) {
      for (final host in scout.candidates.take(3).toList()) {
        if (tried.add(scout.keyOf(host))) routes.add(lanRoute(host));
      }
    }
    final hinted = _lanHintHost(saved);
    if (hinted != null &&
        tried.add('${hinted.address.address}:${hinted.port}') &&
        (pinnedLan || scout == null || !scout.inCooldown(hinted))) {
      routes.add(lanRoute(hinted));
    }
    if (pinnedLan) return routes;
    return [...routes, for (final url in _relayOrder(saved)) relayRoute(url)];
  }

  Future<SealedHostLink?> _attemptLan(
    CompanionPairing pairing,
    List<String> notes,
    DiscoveredHost host, {
    required bool pinned,
    DesktopLinkResume? resume,
  }) async {
    final scout = this.scout;
    final link = await _attempt(
      pairing,
      notes,
      label: '${host.address.address}:${host.port}',
      path: host.tag == _kLanHintTag ? 'lan (announced address)' : 'lan',
      timeout: pinned ? timeout : lanTimeout,
      open: (_) async => scout != null
          ? scout.dial(host)
          : _lanDialer(host.address.address, host.port),
      resume: resume,
    );
    if (scout != null) {
      if (link == null) {
        scout.noteFailure(host);
      } else {
        scout.noteSuccess(host);
      }
    }
    return link;
  }

  Future<SealedHostLink?> _attemptRelay(
    CompanionPairing pairing,
    Uri url,
    List<String> notes, {
    DesktopLinkResume? resume,
  }) async {
    final key = SecretKeyData(pairing.deviceKey);
    final link = await _attempt(
      pairing,
      notes,
      // The host alone: a relay's URL can carry its access token.
      label: 'relay ${url.host}',
      path: 'relay',
      timeout: timeout,
      relay: url,
      open: (generation) async =>
          _relayFactory(url, await rendezvousFor(key, generation)),
      resume: resume,
    );
    if (link == null) await _noteRelayFailure(pairing, url);
    return link;
  }

  /// One route, walked across the generation window. Only a route that took
  /// the socket is asked again one generation later: a server whose counter
  /// moved on hangs up on a rendezvous it no longer holds.
  Future<SealedHostLink?> _attempt(
    CompanionPairing pairing,
    List<String> notes, {
    required String label,
    required String path,
    required Duration timeout,
    required Future<RemoteTransport> Function(int generation) open,
    Uri? relay,
    DesktopLinkResume? resume,
  }) async {
    for (var probe = 0; probe < kCompanionProbeWindow; probe++) {
      final generation = pairing.generation + probe;
      onLog?.call('dialling ${pairing.hostName} over $path at $label');
      final transport = await open(generation);
      var socketOpened = false;
      final watching = transport.states.listen((state) {
        if (state == TransportState.connected) socketOpened = true;
      });
      RemoteHostStatus? status;
      try {
        final link = await connectDesktopLink(
          pairing: pairing,
          transport: transport,
          generation: generation,
          timeout: timeout,
          onHostStatus: (announced) => status = announced,
          resume: resume,
        );
        onLog?.call('connected to ${pairing.hostName} over $path at $label');
        await _settle(pairing, generation, status, relay: relay);
        return link;
      } on DesktopConnectException catch (error) {
        if (error.refused) rethrow;
        notes.add('$label: ${error.message}');
        onLog?.call('$path attempt at $label failed: ${error.message}');
        if (!socketOpened) break;
      } finally {
        await watching.cancel();
      }
    }
    return null;
  }

  /// The server's announced LAN address as a sighting to dial. A hint, not an
  /// identity: DHCP may have moved it, and only the sealed hello decides.
  DiscoveredHost? _lanHintHost(CompanionPairing pairing) {
    final hint = parseLanHint(pairing.lanHint);
    if (hint == null) return null;
    final address = InternetAddress.tryParse(hint.host);
    if (address == null) return null;
    return DiscoveredHost(
      address: address,
      advert: LanAdvert(port: hint.port, tag: _kLanHintTag),
      seenAt: _now(),
    );
  }

  /// The relays to try, in order: the record's candidates by health, then the
  /// relay it was paired at. A pairing made without one names
  /// `invalid.local`, which is nowhere.
  List<Uri> _relayOrder(CompanionPairing pairing) => [
    for (final url in orderRelayCandidates(
      pairing.candidates,
      fallback: pairing.relay,
      now: _now(),
    ))
      if (url.host != 'invalid.local') url,
  ];

  /// After a link: the counter moves on, and what the server just announced
  /// in `host.status` — its relays, health carried over, and its LAN address
  /// — is folded into the saved record, as the phone does. Read from the
  /// store rather than [pairing], so a write in between is kept.
  Future<void> _settle(
    CompanionPairing pairing,
    int used,
    RemoteHostStatus? status, {
    Uri? relay,
  }) async {
    final at = _now();
    try {
      await CompanionConnections.mutate(store, (all) {
        final saved = all.byHost(pairing.hostId.value) ?? pairing;
        var candidates = mergeRelayCandidates(
          saved.candidates,
          status?.relays ?? const [],
        );
        if (relay != null) {
          final key = relay.toString();
          candidates = [
            for (final candidate in candidates)
              candidate.key == key ? candidate.succeededAt(at) : candidate,
            if (!candidates.any((candidate) => candidate.key == key))
              RelayCandidate(url: relay).succeededAt(at),
          ];
        }
        all.upsert(
          saved.copyWith(
            // Never backwards: another dial may have moved it further.
            generation: used + 1 > saved.generation ? used + 1 : null,
            lastConnectedAt: at.toUtc(),
            candidates: candidates,
            lanHint: status?.lanHint,
            relay: relay,
          ),
        );
        return all;
      });
    } on Object catch (error) {
      // A counter that did not stick costs a probe forward next time.
      onLog?.call('saving the link to ${pairing.hostName} failed: $error');
    }
  }

  /// Stamps a relay that did not answer, so the next dial skips it while it
  /// cools. Best effort: a refused write costs ordering, never a link.
  Future<void> _noteRelayFailure(CompanionPairing pairing, Uri url) async {
    final key = url.toString();
    final at = _now();
    try {
      await CompanionConnections.mutate(store, (all) {
        final saved = all.byHost(pairing.hostId.value);
        // The relay paired at is tried without being saved; it earns a place
        // in the set only by working.
        if (saved == null ||
            !saved.candidates.any((candidate) => candidate.key == key)) {
          return all;
        }
        all.upsert(
          saved.copyWith(
            candidates: [
              for (final candidate in saved.candidates)
                candidate.key == key ? candidate.failedAt(at) : candidate,
            ],
          ),
        );
        return all;
      });
    } on Object catch (error) {
      onLog?.call('relay outcome stamp failed: $error');
    }
  }
}

/// The tag a LAN hint is dialled under, so the log tells it from a beacon.
const String _kLanHintTag = 'hint';

/// How long a LAN sighting or hint that is not pinned may take — dial, sealed
/// hello and attach — before the next route is tried.
const Duration kDesktopLanAttemptTimeout = Duration(seconds: 3);

/// How long after beacon listening starts the first dial waits for a first
/// sighting: one beacon interval (`kLanBeaconInterval`) and a little.
const Duration kDesktopFirstSightingWait = Duration(milliseconds: 2500);

/// `host:port` as a pair, or null when [text] is not one.
(String, int)? parseEndpoint(String? text) {
  if (text == null || text.isEmpty) return null;
  final colon = text.lastIndexOf(':');
  if (colon <= 0) return null;
  final port = int.tryParse(text.substring(colon + 1));
  if (port == null || port <= 0 || port > 65535) return null;
  return (text.substring(0, colon), port);
}

/// A sealed host link as the byte channel a host-protocol link runs over.
class SealedHostChannel implements RemoteChannel {
  SealedHostChannel(this.link);

  final SealedHostLink link;

  @override
  Stream<Uint8List> get stdout => link.incoming;

  @override
  Stream<Uint8List> get stderr => const Stream<Uint8List>.empty();

  @override
  void add(Uint8List bytes) => link.add(bytes);

  @override
  Future<int> get exitCode => link.done.then((_) => 0);

  @override
  Future<void> close() async => link.close('the client hung up');
}
