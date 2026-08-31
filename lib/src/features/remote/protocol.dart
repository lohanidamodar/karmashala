/// The wire protocol shared by the desktop host, the relay client and the
/// mobile companion.
///
/// Pure Dart on purpose: no Flutter, no `dart:io`, no plugins, so the relay
/// tooling and any future non-Flutter implementation can depend on it.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// The envelope version this build speaks.
const int kProtocolVersion = 1;

/// Envelope versions this build can decode.
const VersionRange kSupportedVersions = VersionRange(1, 1);

/// Largest envelope this build will decode, in bytes.
const int kMaxEnvelopeBytes = 1024 * 1024;

/// A malformed or unacceptable frame. Never carries payload content, so it is
/// safe to log.
class ProtocolException implements Exception {
  const ProtocolException(this.message);

  final String message;

  @override
  String toString() => 'ProtocolException: $message';
}

/// An envelope whose version falls outside the receiver's supported range.
class UnsupportedProtocolVersion implements Exception {
  const UnsupportedProtocolVersion(this.version, this.supported);

  final int version;
  final VersionRange supported;

  @override
  String toString() =>
      'UnsupportedProtocolVersion: peer speaks v$version, this build accepts '
      '$supported';
}

/// An inclusive range of protocol versions.
class VersionRange {
  const VersionRange(this.min, this.max) : assert(min <= max);

  /// Accepts anything a valid envelope can carry. Used when a receiver wants to
  /// decode an out-of-range frame in order to answer it with an error.
  static const VersionRange any = VersionRange(0, 0x7fffffff);

  final int min;
  final int max;

  bool contains(int version) => version >= min && version <= max;

  /// The overlap with [other], or null when the two cannot talk.
  VersionRange? intersect(VersionRange other) {
    final lo = min > other.min ? min : other.min;
    final hi = max < other.max ? max : other.max;
    return lo <= hi ? VersionRange(lo, hi) : null;
  }

  /// The highest version both sides speak, or null when there is none.
  int? negotiate(VersionRange other) => intersect(other)?.max;

  Map<String, Object?> toJson() => {'min': min, 'max': max};

  factory VersionRange.fromJson(Map<String, Object?> json) {
    final min = json['min'];
    final max = json['max'];
    if (min is! int || max is! int || min > max || min < 0) {
      throw const ProtocolException('bad version range');
    }
    return VersionRange(min, max);
  }

  @override
  bool operator ==(Object other) =>
      other is VersionRange && other.min == min && other.max == max;

  @override
  int get hashCode => Object.hash(min, max);

  @override
  String toString() => min == max ? 'v$min' : 'v$min-v$max';
}

/// What the phone was granted at pairing. Enforced by the host, per frame.
enum Capability {
  viewSessions('view_sessions', 1 << 0),
  readTranscript('read_transcript', 1 << 1),
  sendPrompt('send_prompt', 1 << 2),
  approve('approve', 1 << 3),
  receiveNotifications('receive_notifications', 1 << 4),

  /// Read the desktop's projects and installed agents, and start a session in
  /// one of them.
  ///
  /// The only capability that makes the desktop *originate* work rather than
  /// observe or answer it, which is why it is its own bit rather than a second
  /// meaning for [sendPrompt]: a phone paired before this existed holds a
  /// bitset without it and is refused, in words, for ever — nothing already
  /// granted quietly grows into permission to start processes.
  startSession('start_session', 1 << 5);

  const Capability(this.wire, this.bit);

  final String wire;
  final int bit;

  static Capability? tryParse(String wire) => _byWire[wire];

  static final Map<String, Capability> _byWire = {
    for (final c in Capability.values) c.wire: c,
  };
}

/// A set of [Capability] as the bitset carried in the pairing payload.
///
/// Bits this build does not know are preserved on round-trip but grant nothing.
class CapabilitySet {
  const CapabilitySet(this.bits);

  factory CapabilitySet.of(Iterable<Capability> capabilities) =>
      CapabilitySet(capabilities.fold(0, (bits, c) => bits | c.bit));

  static const CapabilitySet none = CapabilitySet(0);

  /// Everything this build knows about — the most a pairing can grant here.
  static final CapabilitySet all = CapabilitySet.of(Capability.values);

  final int bits;

  bool has(Capability capability) => bits & capability.bit != 0;

  /// Whether a frame of [type] is allowed. Types with no capability (events and
  /// errors from the host) are always allowed.
  bool allows(FrameType type) {
    final needed = type.capability;
    return needed == null || has(needed);
  }

  Set<Capability> get granted => {
    for (final c in Capability.values)
      if (has(c)) c,
  };

  CapabilitySet operator |(CapabilitySet other) =>
      CapabilitySet(bits | other.bits);

  CapabilitySet operator &(CapabilitySet other) =>
      CapabilitySet(bits & other.bits);

  int toJson() => bits;

  factory CapabilitySet.fromJson(Object? json) {
    if (json is! int || json < 0) {
      throw const ProtocolException('bad capability bitset');
    }
    return CapabilitySet(json);
  }

  @override
  bool operator ==(Object other) =>
      other is CapabilitySet && other.bits == bits;

  @override
  int get hashCode => bits.hashCode;

  @override
  String toString() => 'CapabilitySet(${granted.map((c) => c.wire).join(',')})';
}

/// Which end is allowed to send a frame type.
enum FrameOrigin { companion, host, either }

/// The frame types of the session API.
enum FrameType {
  sessionsList(
    'sessions.list',
    origin: FrameOrigin.companion,
    capability: Capability.viewSessions,
  ),
  sessionSubscribe(
    'session.subscribe',
    origin: FrameOrigin.companion,
    capability: Capability.viewSessions,
  ),
  sessionUnsubscribe(
    'session.unsubscribe',
    origin: FrameOrigin.companion,
    capability: Capability.viewSessions,
  ),
  transcriptGet(
    'transcript.get',
    origin: FrameOrigin.companion,
    capability: Capability.readTranscript,
  ),
  promptSend(
    'prompt.send',
    origin: FrameOrigin.companion,
    capability: Capability.sendPrompt,
  ),
  approvalAnswer(
    'approval.answer',
    origin: FrameOrigin.companion,
    capability: Capability.approve,
  ),
  notificationsRegister(
    'notifications.register',
    origin: FrameOrigin.companion,
    capability: Capability.receiveNotifications,
  ),

  /// What could be started here: projects, their checkouts, and the agents
  /// actually installed where each checkout lives.
  ///
  /// Gated on [Capability.startSession] rather than on `view_sessions`
  /// because it says more than the session rows do — every project on the
  /// machine, whether or not anything has ever run in it — and it exists for
  /// exactly one purpose, which is to make [sessionStart] a real choice.
  workspaceList(
    'workspace.list',
    origin: FrameOrigin.companion,
    capability: Capability.startSession,
  ),
  sessionStart(
    'session.start',
    origin: FrameOrigin.companion,
    capability: Capability.startSession,
  ),
  sessionChanged('session.changed', origin: FrameOrigin.host),
  transcriptAppended('transcript.appended', origin: FrameOrigin.host),
  approvalRequested('approval.requested', origin: FrameOrigin.host),
  hostStatus('host.status', origin: FrameOrigin.host),

  /// The answer to a request, correlated by `id`.
  result('result', origin: FrameOrigin.host),

  /// A refusal, correlated by `id` when it answers a request.
  error('error', origin: FrameOrigin.either);

  const FrameType(this.wire, {required this.origin, this.capability});

  final String wire;
  final FrameOrigin origin;

  /// The capability the companion must hold to send this. Null for host frames.
  final Capability? capability;

  /// Whether [origin] may send this frame type.
  bool sentBy(FrameOrigin end) => origin == FrameOrigin.either || origin == end;

  static FrameType? tryParse(String wire) => _byWire[wire];

  static final Map<String, FrameType> _byWire = {
    for (final t in FrameType.values) t.wire: t,
  };
}

/// Reasons an [FrameType.error] frame carries, as `p.code`.
enum ErrorCode {
  unsupportedVersion('unsupported_version'),
  unknownType('unknown_type'),
  notPermitted('not_permitted'),
  badRequest('bad_request'),
  notFound('not_found'),
  internal('internal');

  const ErrorCode(this.wire);

  final String wire;

  static ErrorCode? tryParse(String wire) => _byWire[wire];

  static final Map<String, ErrorCode> _byWire = {
    for (final c in ErrorCode.values) c.wire: c,
  };
}

/// A 16-byte identity for one paired end (a desktop host or a phone).
class DeviceId {
  DeviceId(Uint8List bytes) : bytes = Uint8List.fromList(bytes) {
    if (bytes.length != lengthInBytes) {
      throw ProtocolException('device id must be $lengthInBytes bytes');
    }
  }

  factory DeviceId.generate([Random? random]) {
    final rng = random ?? Random.secure();
    return DeviceId(
      Uint8List.fromList([
        for (var i = 0; i < lengthInBytes; i++) rng.nextInt(256),
      ]),
    );
  }

  factory DeviceId.parse(String value) =>
      DeviceId(_parseHex(value, lengthInBytes, 'device id'));

  static const int lengthInBytes = 16;

  final Uint8List bytes;

  /// The lowercase hex form used on the wire and in storage.
  String get value => _toHex(bytes);

  @override
  bool operator ==(Object other) =>
      other is DeviceId && _bytesEqual(other.bytes, bytes);

  @override
  int get hashCode => Object.hashAll(bytes);

  @override
  String toString() => 'DeviceId($value)';
}

/// The relay path two ends meet on. Rotates per connection, so the relay cannot
/// link one device's connections to each other.
class RendezvousId {
  RendezvousId(Uint8List bytes) : bytes = Uint8List.fromList(bytes) {
    if (bytes.length != lengthInBytes) {
      throw ProtocolException('rendezvous id must be $lengthInBytes bytes');
    }
  }

  factory RendezvousId.parse(String value) =>
      RendezvousId(_parseHex(value, lengthInBytes, 'rendezvous id'));

  static const int lengthInBytes = 16;

  /// What the relay accepts as a path segment.
  static final RegExp pattern = RegExp('^[0-9a-f]{${lengthInBytes * 2}}\$');

  final Uint8List bytes;

  /// The lowercase hex form used as the relay's URL path segment.
  String get value => _toHex(bytes);

  @override
  bool operator ==(Object other) =>
      other is RendezvousId && _bytesEqual(other.bytes, bytes);

  @override
  int get hashCode => Object.hashAll(bytes);

  @override
  String toString() => 'RendezvousId($value)';
}

/// The one JSON envelope carried inside every sealed frame.
///
/// `seq` is the sender's per-direction frame number; it is the same number the
/// sealing layer stamps inside the sealed payload, so a receiver can check the
/// two agree.
class Envelope {
  Envelope({
    required this.seq,
    required this.type,
    this.version = kProtocolVersion,
    this.id,
    Map<String, Object?> payload = const <String, Object?>{},
  }) : payload = Map<String, Object?>.unmodifiable(payload) {
    if (seq < 0 || seq > maxSequence) {
      throw ProtocolException('seq out of range: $seq');
    }
    if (type.isEmpty) throw const ProtocolException('empty frame type');
  }

  /// Builds an envelope for a type this build knows.
  Envelope.of(
    FrameType type, {
    required int seq,
    String? id,
    Map<String, Object?> payload = const <String, Object?>{},
    int version = kProtocolVersion,
  }) : this(
         seq: seq,
         type: type.wire,
         id: id,
         payload: payload,
         version: version,
       );

  /// JSON integers stay exact below 2^53, which is also well past any session.
  static const int maxSequence = 0x1fffffffffffff;

  final int version;
  final int seq;

  /// The wire type. Kept as a string so an unknown type from a newer peer
  /// survives decoding and can be answered rather than dropping the connection.
  final String type;

  /// Request id, echoed on the matching `result` or `error`.
  final String? id;
  final Map<String, Object?> payload;

  /// The parsed type, or null when the peer sent something this build predates.
  FrameType? get knownType => FrameType.tryParse(type);

  Map<String, Object?> toJson() => {
    'v': version,
    'seq': seq,
    't': type,
    if (id != null) 'id': id,
    'p': payload,
  };

  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  factory Envelope.fromJson(
    Map<String, Object?> json, {
    VersionRange accept = kSupportedVersions,
  }) {
    final version = json['v'];
    if (version is! int) throw const ProtocolException('missing v');
    if (!accept.contains(version)) {
      throw UnsupportedProtocolVersion(version, accept);
    }
    final seq = json['seq'];
    if (seq is! int) throw const ProtocolException('missing seq');
    final type = json['t'];
    if (type is! String) throw const ProtocolException('missing t');
    final id = json['id'];
    if (id != null && id is! String) throw const ProtocolException('bad id');
    final payload = json['p'];
    if (payload != null && payload is! Map<String, Object?>) {
      throw const ProtocolException('bad p');
    }
    return Envelope(
      version: version,
      seq: seq,
      type: type,
      id: id as String?,
      payload: (payload as Map<String, Object?>?) ?? const <String, Object?>{},
    );
  }

  factory Envelope.fromBytes(
    List<int> bytes, {
    VersionRange accept = kSupportedVersions,
  }) {
    if (bytes.length > kMaxEnvelopeBytes) {
      throw ProtocolException('envelope too large: ${bytes.length} bytes');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const ProtocolException('envelope is not valid JSON');
    }
    if (decoded is! Map<String, Object?>) {
      throw const ProtocolException('envelope is not a JSON object');
    }
    return Envelope.fromJson(decoded, accept: accept);
  }

  @override
  String toString() => 'Envelope(v$version seq=$seq t=$type id=$id)';
}

String _toHex(Uint8List bytes) {
  final out = StringBuffer();
  for (final b in bytes) {
    out.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

Uint8List _parseHex(String value, int expectedBytes, String what) {
  if (value.length != expectedBytes * 2) {
    throw ProtocolException('$what must be ${expectedBytes * 2} hex chars');
  }
  final out = Uint8List(expectedBytes);
  for (var i = 0; i < expectedBytes; i++) {
    final byte = int.tryParse(value.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null || value.toLowerCase() != value) {
      throw ProtocolException('$what is not lowercase hex');
    }
    out[i] = byte;
  }
  return out;
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
