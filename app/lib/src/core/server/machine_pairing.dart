import 'dart:async';
import 'dart:io';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/companion.dart'
    show RemoteCompanionGateway, kDefaultCompanionRelayUrl;
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';

/// Pairs this client with a server on another machine (slice 5e): the code
/// `karmashala_host pair` prints (or a desktop's pairing dialog shows), as its
/// QR text, its host invite or the typed code with the address it is reached
/// at. [hostsServer] is `ClientCapabilities.hostsServer`: a desktop needs the
/// `desktop_client` grant, a client that cannot host (a phone) that or
/// `phone_client`. The record is saved in [store]; throws
/// [CompanionPairingException] in words.
///
/// A phone races the ways a code can reach its server, as the companion did:
/// the typed address, the server's LAN beacon (heard with [lanLock] held, or
/// on [scout] when one is given) and the relay, first sealed confirm wins.
/// A desktop's code or invite names its one route.
Future<CompanionPairing> pairWithMachine({
  required CompanionStore store,
  required String code,
  String? address,
  String? deviceName,
  bool hostsServer = true,
  MulticastLockHolder? lanLock,
  LanPathScout? scout,
  RemoteTransport Function(String host, int port)? lanDialer,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final text = code.trim();
  // The pairing lands in [store] only once it is usable: a refused re-pair
  // must not replace the working record of the machine in use.
  final staged = InMemoryCompanionStore();
  final client = CompanionPairingClient(
    store: staged,
    deviceId: hostsServer
        ? await _deviceId(store)
        : await _phoneDeviceId(store),
    deviceName: _machineName(deviceName),
  );
  RemoteTransport? lan(String? endpoint) {
    final at = parseEndpoint(endpoint);
    if (at == null) return null;
    return (lanDialer ?? _dialLan)(at.$1, at.$2);
  }

  final typedAddress = address?.trim().isEmpty ?? true ? null : address!.trim();
  if (typedAddress != null && parseEndpoint(typedAddress) == null) {
    throw const CompanionPairingException(
      'The address is host:port — the server\'s address and its phone '
      'listener\'s port (47820 unless its server.json says otherwise).',
    );
  }

  CompanionPairing record;
  String? direct;
  String? heardAt;
  if (HostPairingInvite.looksLike(text)) {
    final HostPairingInvite invite;
    try {
      invite = HostPairingInvite.decode(text);
    } on HostInviteExpiredException catch (error) {
      throw CompanionPairingException(error.message);
    } on HostInviteTooNewException {
      throw const CompanionPairingException(
        'This code was made by a newer Karmashala. Update this app, then '
        'try it again.',
      );
    } on ProtocolException {
      throw const CompanionPairingException('That is not a Karmashala code.');
    }
    direct = invite.route == HostRoute.direct ? invite.endpoint : typedAddress;
    record = await client.pairWithTypedCode(
      codeSecret: PairingCode.tryDecode(invite.code)!,
      relay: invite.relay ?? Uri.parse('https://invalid.local'),
      transport: lan(direct),
      timeout: timeout,
    );
  } else if (text.startsWith('{')) {
    final PairingPayload payload;
    try {
      payload = PairingPayload.decode(text);
    } on Object {
      throw const CompanionPairingException('That is not a Karmashala code.');
    }
    direct = typedAddress;
    final namesRelay = payload.relay.host != 'invalid.local';
    if (!hostsServer) {
      // "Pair a phone" on a desktop with no relay: the phone meets it on
      // this network, by its beacon, or at the address typed.
      final raced = await _raceLegs(
        attempt: (transport) =>
            client.pair(payload, transport: transport, timeout: timeout),
        direct: parseEndpoint(direct),
        relay: namesRelay ? payload.relay : null,
        rendezvous: payload.rendezvous,
        lanLock: lanLock,
        scout: scout,
        lanDialer: lanDialer ?? _dialLan,
        timeout: timeout,
      );
      record = raced.record;
      heardAt = raced.at;
      if (raced.leg != _Leg.direct) direct = null;
    } else {
      if (direct == null && !namesRelay) {
        throw const CompanionPairingException(
          'This code names no relay: give the server\'s address too.',
        );
      }
      record = await client.pair(
        payload,
        transport: lan(direct),
        timeout: timeout,
      );
    }
  } else {
    final secret = PairingCode.tryDecode(text);
    if (secret == null) {
      throw CompanionPairingException(
        'That is not a Karmashala code. Paste the code `karmashala_host pair'
        '${hostsServer ? ' --grants desktop' : ''}` printed, or its payload.',
      );
    }
    // With no address, a phone meets the server on this network or on the
    // relay the companion used for typed codes; a desktop is always told
    // where the server is.
    final relay = typedAddress == null && !hostsServer
        ? await _pairingRelay(store)
        : null;
    if (typedAddress == null && relay == null) {
      throw const CompanionPairingException(
        'A typed code needs the server\'s address (host:port), or paste the '
        'whole payload instead.',
      );
    }
    direct = typedAddress;
    Future<CompanionPairing> attempt(RemoteTransport? transport) =>
        client.pairWithTypedCode(
          codeSecret: secret,
          relay: relay ?? Uri.parse('https://invalid.local'),
          transport: transport,
          timeout: timeout,
        );
    if (!hostsServer) {
      final raced = await _raceLegs(
        attempt: attempt,
        direct: parseEndpoint(direct),
        relay: relay,
        // Both ends derive the rendezvous from the code alone.
        rendezvous: await derivePairingRendezvous(
          (await derivePairingSecret(secret)).bytes,
        ),
        lanLock: lanLock,
        scout: scout,
        lanDialer: lanDialer ?? _dialLan,
        timeout: timeout,
      );
      record = raced.record;
      heardAt = raced.at;
      if (raced.leg != _Leg.direct) direct = null;
    } else {
      record = await attempt(lan(direct));
    }
  }
  final usable = hostsServer
      ? record.capabilities.has(Capability.desktopClient)
      : record.capabilities.attachTier != null;
  if (!usable) {
    throw CompanionPairingException(
      hostsServer
          ? 'That code pairs a phone, not a desktop. On the server run '
                '`karmashala_host pair --grants desktop` for a code this app '
                'can use.'
          // The confirm carries no server version, so both causes are named.
          : 'That code pairs the old phone companion, not this app. On the '
                'server, pair again: `karmashala_host pair` (its default now '
                'includes the app), or `--grants phone`. If the server does '
                'not know `phone`, it is older than this app: update it '
                'first.',
    );
  }
  if (direct != null) {
    record = record.copyWith(directEndpoint: direct, route: HostRoute.direct);
  } else if (heardAt != null) {
    // Found by its beacon: where it was heard is the first dial's LAN hint,
    // until its own `host.status` names one.
    record = record.copyWith(lanHint: heardAt);
  }
  await record.save(store);
  return record;
}

const _deviceIdKey = 'karmashala.desktop.deviceId';

/// This desktop's identity at every server it pairs with: minted once, so
/// pairing the same server again refreshes its row rather than adding one.
Future<DeviceId> _deviceId(CompanionStore store) async {
  final saved = await store.read(_deviceIdKey);
  if (saved != null) {
    try {
      return DeviceId.parse(saved);
    } on ProtocolException {
      // Minted again below.
    }
  }
  final minted = DeviceId.generate();
  await store.write(_deviceIdKey, minted.value);
  return minted;
}

/// A phone's identity is the companion's (`karmashala.remote.device_id`, else
/// its active record's), so a server sees the same device across the move.
Future<DeviceId> _phoneDeviceId(CompanionStore store) async {
  const key = RemoteCompanionGateway.kDeviceIdStoreKey;
  final saved = await store.read(key);
  if (saved != null) {
    try {
      return DeviceId.parse(saved);
    } on ProtocolException {
      // Inherited or minted below.
    }
  }
  final connections = await CompanionConnections.load(store);
  final id = connections.active?.deviceId ?? DeviceId.generate();
  await store.write(key, id.value);
  return id;
}

/// The relay a phone's typed code meets its server on: the companion's
/// setting, else the default.
Future<Uri> _pairingRelay(CompanionStore store) async {
  final raw = await store.read(RemoteCompanionGateway.kPairingRelayStoreKey);
  final parsed = raw == null ? null : Uri.tryParse(raw.trim());
  if (parsed != null && parsed.hasScheme) return parsed;
  return Uri.parse(kDefaultCompanionRelayUrl);
}

String _machineName(String? given) {
  final name = (given ?? Platform.localHostname).trim();
  if (name.isEmpty) return 'Karmashala desktop';
  return name.length > 64 ? name.substring(0, 64) : name;
}

RemoteTransport _dialLan(String host, int port) =>
    LanTransport.dial(host: host, port: port);

enum _Leg { direct, lan, relay }

/// A refusal that says something about the code or the server, rather than
/// that nothing answered: it beats the connectivity sentence.
bool _isSharp(CompanionPairingException error) =>
    !error.message.contains('did not answer') &&
    !error.message.contains('connection closed');

/// The companion gateway's pairing race (`_pairOverAnyPath`) for a phone:
/// the typed address, every fresh beacon sighting and the relay at once; the
/// first sealed confirm wins and every other transport is closed under it.
/// When all fail, one sentence says what each found.
/// The record, the leg that won, and for a beacon sighting where it was.
typedef _Raced = ({CompanionPairing record, _Leg leg, String? at});

Future<_Raced> _raceLegs({
  required Future<CompanionPairing> Function(RemoteTransport transport)
  attempt,
  required (String, int)? direct,
  required Uri? relay,
  required RendezvousId rendezvous,
  required MulticastLockHolder? lanLock,
  required LanPathScout? scout,
  required RemoteTransport Function(String host, int port) lanDialer,
  required Duration timeout,
}) async {
  final ownScout = scout == null;
  final lan =
      scout ??
      LanPathScout(
        lock: lanLock,
        dialer: lanDialer,
        onLog: _pairingLog.info,
      );
  if (ownScout) await lan.start();

  final outcome = Completer<_Raced>();
  final open = <RemoteTransport>{};
  var over = false;
  String? directNote;
  String? lanNote;
  String? relayNote;
  CompanionPairingException? sharp;

  Future<void> closeQuietly(RemoteTransport transport) async {
    if (!open.remove(transport)) return;
    try {
      await transport.close();
    } on Object {
      // Already gone.
    }
  }

  /// One attempt over [transport]; null when it paired, else whether the
  /// socket ever connected.
  Future<bool?> run(
    RemoteTransport transport,
    _Leg leg,
    Duration within, {
    String? at,
  }) async {
    open.add(transport);
    var connected = false;
    final states = transport.states.listen((state) {
      if (state == TransportState.connected) connected = true;
    });
    try {
      final record = await attempt(transport).timeout(within);
      if (!outcome.isCompleted) {
        outcome.complete((record: record, leg: leg, at: at));
      }
      return null;
    } on CompanionPairingException catch (error) {
      _pairingLog.info('${leg.name} pairing leg failed: ${error.message}');
      if (_isSharp(error)) sharp ??= error;
    } on Object catch (error) {
      _pairingLog.info('${leg.name} pairing leg failed: $error');
    } finally {
      await states.cancel();
      await closeQuietly(transport);
    }
    return connected;
  }

  Future<void> directLeg() async {
    if (direct == null) return;
    final at = '${direct.$1}:${direct.$2}';
    final connected = await run(
      lanDialer(direct.$1, direct.$2),
      _Leg.direct,
      timeout,
    );
    if (connected == null) return;
    directNote = connected
        ? '$at answered but did not accept the code'
        : 'nothing answered at $at';
  }

  Future<void> relayLeg() async {
    if (relay == null) return;
    final connected = await run(
      RelayTransport.connect(relay: relay, rendezvous: rendezvous),
      _Leg.relay,
      timeout,
    );
    if (connected == null) return;
    relayNote = connected
        ? 'the relay was reached but the machine never answered there'
        : 'no relay was reachable';
  }

  Future<void> lanLeg() async {
    if (!lan.isListening) {
      lanNote = 'this device could not listen on this network';
      return;
    }
    final deadline = DateTime.now().add(timeout);
    final tried = <String>{};
    var sawBeacon = false;
    while (!over &&
        !outcome.isCompleted &&
        sharp == null &&
        DateTime.now().isBefore(deadline)) {
      DiscoveredHost? candidate;
      for (final host in lan.candidates) {
        if (tried.add(lan.keyOf(host))) {
          candidate = host;
          break;
        }
      }
      if (candidate == null) {
        // The beacon repeats every two seconds.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        continue;
      }
      sawBeacon = true;
      final connected = await run(
        lan.dial(candidate),
        _Leg.lan,
        lan.attemptTimeout * 4,
        at: lan.keyOf(candidate),
      );
      if (connected == null) return;
    }
    lanNote = sawBeacon
        ? 'a machine on this network did not accept the code'
        : 'no machine was found on this network';
  }

  unawaited(
    Future.wait([directLeg(), lanLeg(), relayLeg()]).then((_) {
      if (outcome.isCompleted) return;
      final specific = sharp;
      if (specific != null) {
        outcome.completeError(specific);
        return;
      }
      if (directNote != null) {
        outcome.completeError(
          CompanionPairingException(
            'Could not pair — $directNote. Check the address and port, that '
            'the server is running there, and that the code has not expired.',
          ),
        );
        return;
      }
      outcome.completeError(
        CompanionPairingException(
          relay == null
              ? 'This code names no relay, and $lanNote. Join the same '
                    'network as the machine, or add it by address.'
              : 'Could not find the machine — $relayNote, and $lanNote. Make '
                    'sure the pairing code is still showing on it, then retry.',
        ),
      );
    }),
  );
  try {
    return await outcome.future;
  } finally {
    over = true;
    for (final transport in open.toList()) {
      await closeQuietly(transport);
    }
    if (ownScout) await lan.stop();
  }
}

final AppLogger _pairingLog = AppLogger.named('pairing');
