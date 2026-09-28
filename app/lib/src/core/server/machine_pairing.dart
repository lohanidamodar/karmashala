import 'dart:io';

import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';

/// Pairs this desktop with a server on another machine (slice 5e), as a
/// phone adds a machine: the code `karmashala_host pair --grants desktop`
/// prints (or another desktop's pairing dialog shows), as its QR text, its
/// host invite or the typed code with the address it is reached at. The
/// record is saved in [store]; throws [CompanionPairingException] in words.
Future<CompanionPairing> pairWithMachine({
  required CompanionStore store,
  required String code,
  String? address,
  RemoteTransport Function(String host, int port)? lanDialer,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final text = code.trim();
  final client = CompanionPairingClient(
    store: store,
    deviceId: await _deviceId(store),
    deviceName: _machineName(),
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
      throw const CompanionPairingException(
        'That is not a Karmashala code. Paste the code `karmashala_host pair '
        '--grants desktop` printed, or its payload.',
      );
    }
    if (typedAddress == null) {
      throw const CompanionPairingException(
        'A typed code needs the server\'s address (host:port), or paste the '
        'whole payload instead.',
      );
    }
    direct = typedAddress;
    record = await client.pairWithTypedCode(
      codeSecret: secret,
      relay: Uri.parse('https://invalid.local'),
      transport: lan(direct),
      timeout: timeout,
    );
  }
  if (!record.capabilities.has(Capability.desktopClient)) {
    await CompanionConnections.mutate(
      store,
      (all) => all.remove(record.hostId.value),
    );
    throw const CompanionPairingException(
      'That code pairs a phone, not a desktop. On the server run '
      '`karmashala_host pair --grants desktop` for a code this app can use.',
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

String _machineName() {
  final name = Platform.localHostname.trim();
  if (name.isEmpty) return 'Karmashala desktop';
  return name.length > 64 ? name.substring(0, 64) : name;
}

RemoteTransport _dialLan(String host, int port) =>
    LanTransport.dial(host: host, port: port);
