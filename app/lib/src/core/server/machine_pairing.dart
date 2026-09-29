import 'dart:io';

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
Future<CompanionPairing> pairWithMachine({
  required CompanionStore store,
  required String code,
  String? address,
  String? deviceName,
  bool hostsServer = true,
  RemoteTransport Function(String host, int port)? lanDialer,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final text = code.trim();
  final client = CompanionPairingClient(
    store: store,
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
    if (direct == null && payload.relay.host == 'invalid.local') {
      throw const CompanionPairingException(
        'This code names no relay: give the server\'s address too.',
      );
    }
    record = await client.pair(
      payload,
      transport: lan(direct),
      timeout: timeout,
    );
  } else {
    final secret = PairingCode.tryDecode(text);
    if (secret == null) {
      throw CompanionPairingException(
        'That is not a Karmashala code. Paste the code `karmashala_host pair'
        '${hostsServer ? ' --grants desktop' : ''}` printed, or its payload.',
      );
    }
    // With no address, a phone meets the server on the relay the companion
    // used for typed codes; a desktop is always told where the server is.
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
    record = await client.pairWithTypedCode(
      codeSecret: secret,
      relay: relay ?? Uri.parse('https://invalid.local'),
      transport: lan(direct),
      timeout: timeout,
    );
  }
  final usable = hostsServer
      ? record.capabilities.has(Capability.desktopClient)
      : record.capabilities.attachTier != null;
  if (!usable) {
    await CompanionConnections.mutate(
      store,
      (all) => all.remove(record.hostId.value),
    );
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
    await record.save(store);
  }
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
