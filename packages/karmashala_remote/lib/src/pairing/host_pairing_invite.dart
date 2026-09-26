/// What the QR for a session host on a box carries: the pairing QR's JSON with
/// a `kind`, because the desktop showing it is not the peer being paired and
/// holds only what it was told — an address, a typed code and when it expires.
library;

import 'dart:convert';

import '../client/relay_candidates.dart';
import '../protocol.dart';
import 'pairing_code.dart';

/// The `kind` a host invite carries. A desktop's own payload carries none.
const String kHostInviteKind = 'host';

/// The invite format this build writes, and the newest it reads.
const int kHostInviteVersion = 1;

/// How a phone reaches a session host. Chosen on the desktop, per host, and
/// never switched silently: the two routes show different parties the traffic.
enum HostRoute {
  /// Straight TCP to the box's own address. No third machine.
  direct('direct'),

  /// Through the hosted relay, for a box the phone cannot dial.
  relay('relay');

  const HostRoute(this.wire);

  final String wire;

  static HostRoute? tryParse(Object? value) => switch (value) {
    'direct' => HostRoute.direct,
    'relay' => HostRoute.relay,
    _ => null,
  };
}

/// An invite that is past its `exp`. Separate from a malformed one: the remedy
/// is a new code from the machine, not "that is not a Karmashala code".
class HostInviteExpiredException implements Exception {
  const HostInviteExpiredException();

  String get message =>
      'That code has expired. Get a new code from the machine and scan again.';

  @override
  String toString() => message;
}

/// An invite in a format newer than this build reads. Still a
/// [ProtocolException], so a caller that only knows "not an invite" is right;
/// one that can say "update this app" can tell.
class HostInviteTooNewException extends ProtocolException {
  const HostInviteTooNewException()
    : super('this code was made by a newer Karmashala — update this app');
}

/// One scan's worth of pairing with a box: where, with what code, by which
/// route, until when.
class HostPairingInvite {
  HostPairingInvite({
    required this.endpoint,
    required this.code,
    required this.hostName,
    required this.route,
    required this.expiresAt,
    this.relay,
    this.version = kHostInviteVersion,
    this.protocolVersion = kProtocolVersion,
  }) {
    if (parseLanHint(endpoint) == null) {
      throw ArgumentError.value(endpoint, 'endpoint', 'must be host:port');
    }
    if (PairingCode.tryDecode(code) == null) {
      throw ArgumentError.value('<redacted>', 'code', 'not a pairing code');
    }
    if (route == HostRoute.relay && relay == null) {
      throw ArgumentError.notNull('relay');
    }
  }

  /// `host:port` of the box's companion listener — what the desktop connected
  /// with, never something the box said about itself.
  final String endpoint;

  /// The grouped typed code. The only secret here, single-use and short-lived.
  final String code;

  final String hostName;
  final HostRoute route;

  /// Where both ends meet when [route] is [HostRoute.relay]; null otherwise.
  final Uri? relay;

  final DateTime expiresAt;
  final int version;
  final int protocolVersion;

  /// Cheap sniff for a scanner or a paste box; [decode] is the authority.
  static bool looksLike(String text) {
    final trimmed = text.trim();
    return trimmed.startsWith('{') && _kindPattern.hasMatch(trimmed);
  }

  static final RegExp _kindPattern = RegExp(
    '"kind"\\s*:\\s*"$kHostInviteKind"',
  );

  /// The QR's text. Never log it: [code] is the pairing secret.
  String encode() => jsonEncode({
    'kind': kHostInviteKind,
    'v': version,
    'proto': protocolVersion,
    'at': endpoint,
    'code': code,
    'name': hostName,
    'via': route.wire,
    if (relay != null) 'relay': relay.toString(),
    'exp': expiresAt.toUtc().millisecondsSinceEpoch ~/ 1000,
  });

  /// Parses a scanned or pasted invite. Throws [ProtocolException] on anything
  /// that is not one, or is newer than this build reads, and
  /// [HostInviteExpiredException] when [now] is past its expiry.
  static HostPairingInvite decode(String text, {DateTime? now}) {
    final Object? json;
    try {
      json = jsonDecode(text.trim());
    } on FormatException {
      throw const ProtocolException('host invite is not JSON');
    }
    if (json is! Map<String, Object?> || json['kind'] != kHostInviteKind) {
      throw const ProtocolException('not a host invite');
    }
    final version = json['v'];
    if (version is! int || version < 1) {
      throw const ProtocolException('host invite has no version');
    }
    if (version > kHostInviteVersion) {
      throw const HostInviteTooNewException();
    }
    final at = json['at'];
    final code = json['code'];
    final name = json['name'];
    final exp = json['exp'];
    final route = HostRoute.tryParse(json['via']);
    if (at is! String || code is! String || exp is! int || route == null) {
      throw const ProtocolException('host invite is missing fields');
    }
    Uri? relay;
    final rawRelay = json['relay'];
    if (rawRelay is String) {
      final parsed = Uri.tryParse(rawRelay);
      if (parsed != null && parsed.hasScheme) relay = parsed;
    }
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(
      exp * 1000,
      isUtc: true,
    );
    final HostPairingInvite invite;
    try {
      invite = HostPairingInvite(
        endpoint: at,
        code: code,
        hostName: name is String && name.isNotEmpty ? name : at,
        route: route,
        relay: relay,
        expiresAt: expiresAt,
        version: version,
        protocolVersion: json['proto'] is int
            ? json['proto']! as int
            : kProtocolVersion,
      );
    } on ArgumentError {
      throw const ProtocolException('host invite is malformed');
    }
    if (!(now ?? DateTime.now()).toUtc().isBefore(expiresAt)) {
      throw const HostInviteExpiredException();
    }
    return invite;
  }

  @override
  String toString() => 'HostPairingInvite($endpoint, ${route.wire})';
}
