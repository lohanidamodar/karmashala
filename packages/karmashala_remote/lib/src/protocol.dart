/// The wire protocol shared by the desktop host, the relay client and the
/// mobile companion. Pure Dart on purpose: no Flutter, no `dart:io`, no
/// plugins, so a non-Flutter implementation can depend on it.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:karmashala_relay_protocol/karmashala_relay_protocol.dart';

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
  /// one of them. Its own bit rather than a second meaning for [sendPrompt]: a
  /// phone paired before this existed is refused, in words, for ever.
  startSession('start_session', 1 << 5),

  /// Add an existing local desktop folder as a project.
  addProject('add_project', 1 << 6),

  /// Read what a session is **doing right now**: the calls it has issued and
  /// not yet answered. Its own bit for the reason [startSession] states — a
  /// phone paired before this existed is refused, in words, for ever.
  viewActivity('view_activity', 1 << 7),

  /// Put a **file** on the desktop's disk and name its path to an agent. Its
  /// own bit, and the widest gap yet from anything already granted: a phone
  /// paired before this existed is refused, in words, for ever.
  sendAttachment('send_attachment', 1 << 8),

  /// Read the desktop's agent accounts' usage limits — who is signed in, and
  /// how close each is to its limit. Its own bit: a phone paired before this
  /// existed is refused, in words, for ever.
  viewUsage('view_usage', 1 << 9),

  /// Be a **desktop client** of this server (slice 5e): switch the sealed
  /// channel to the host protocol — panes, the data API, the lifecycle feed.
  /// Granted only by name (`pair --grants desktop`), never by "all".
  desktopClient('desktop_client', 1 << 10),

  /// As a desktop client, administer the server: `serverCall` (its config,
  /// devices, agents) and renaming, granting or revoking paired devices.
  serverAdmin('server_admin', 1 << 11),

  /// As a desktop client, be asked — and answer — the server's SSH questions
  /// (host keys, passwords, passphrases). Off unless granted: a secret typed
  /// on another machine crosses the network, if sealed.
  sshPrompts('ssh_prompts', 1 << 12),

  /// Use the Karmashala app on a phone (Stage 1): switch the sealed channel to
  /// the host protocol as a desktop client does, served at the phone tier —
  /// never admin, never SSH prompts, and none of the server's secrets, SSH
  /// hosts or agent accounts. Not privileged, so "all" includes it; a pairing
  /// made before it existed gains it only when granted.
  phoneClient('phone_client', 1 << 13);

  const Capability(this.wire, this.bit);

  final String wire;
  final int bit;

  /// Granted only when named: what makes a pairing a desktop's, not a
  /// phone's. "all" leaves these out.
  bool get privileged =>
      this == desktopClient || this == serverAdmin || this == sshPrompts;

  static Capability? tryParse(String wire) => _byWire[wire];

  static final Map<String, Capability> _byWire = {
    for (final c in Capability.values) c.wire: c,
  };
}

/// A set of [Capability] as the bitset carried in the pairing payload. Bits
/// this build does not know are preserved on round-trip but grant nothing.
class CapabilitySet {
  const CapabilitySet(this.bits);

  factory CapabilitySet.of(Iterable<Capability> capabilities) =>
      CapabilitySet(capabilities.fold(0, (bits, c) => bits | c.bit));

  static const CapabilitySet none = CapabilitySet(0);

  /// Everything a phone may be granted — every capability this build knows
  /// but the [Capability.privileged] ones, which are granted by name.
  static final CapabilitySet all = CapabilitySet.of(
    Capability.values.where((c) => !c.privileged),
  );

  final int bits;

  bool has(Capability capability) => bits & capability.bit != 0;

  /// The tier a `host.attach` is served at, or null when this set may not
  /// attach. [AttachTier.desktop] wins when both bits are held, so a phone
  /// grant never narrows a desktop's.
  AttachTier? get attachTier => has(Capability.desktopClient)
      ? AttachTier.desktop
      : has(Capability.phoneClient)
      ? AttachTier.phone
      : null;

  /// Whether a frame of [type] is allowed. Types with no capability (events and
  /// errors from the host) are always allowed.
  bool allows(FrameType type) {
    if (type == FrameType.hostAttach) return attachTier != null;
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

/// What a switched link is served as: a desktop client, or the app on a
/// phone ([Capability.phoneClient]).
enum AttachTier { desktop, phone }

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

  /// Answers an agent's multiple-choice question with the options the user
  /// chose, or declines it. Gated on [Capability.approve]: choosing for an
  /// agent is the same authority as approving for it.
  questionAnswer(
    'question.answer',
    origin: FrameOrigin.companion,
    capability: Capability.approve,
  ),

  /// Chooses one option of a menu the agent drew on its screen — folder trust,
  /// a permission prompt. Gated on [Capability.approve], like the approval it
  /// replaces.
  menuAnswer(
    'menu.answer',
    origin: FrameOrigin.companion,
    capability: Capability.approve,
  ),
  notificationsRegister(
    'notifications.register',
    origin: FrameOrigin.companion,
    capability: Capability.receiveNotifications,
  ),

  /// What could be started here: projects, checkouts and the agents installed
  /// where each lives. Gated on [Capability.startSession] rather than
  /// `view_sessions`, because it names every project on the machine.
  workspaceList(
    'workspace.list',
    origin: FrameOrigin.companion,
    capability: Capability.startSession,
  ),
  projectsList(
    'projects.list',
    origin: FrameOrigin.companion,
    capability: Capability.viewSessions,
  ),
  projectAdd(
    'project.add',
    origin: FrameOrigin.companion,
    capability: Capability.addProject,
  ),
  sessionStart(
    'session.start',
    origin: FrameOrigin.companion,
    capability: Capability.startSession,
  ),
  sessionResume(
    'session.resume',
    origin: FrameOrigin.companion,
    capability: Capability.startSession,
  ),

  /// **What one session is doing right now** — asked for by the phone, and
  /// stated by the host whenever the answer changes. [FrameOrigin.either], so
  /// one fact is one payload shape and one capability; an unsolicited frame
  /// goes only to a device holding [Capability.viewActivity].
  sessionActivity(
    'session.activity',
    origin: FrameOrigin.either,
    capability: Capability.viewActivity,
  ),

  /// **Ask to send a file**, before any of it has crossed the link, so a
  /// refusal costs one small frame rather than the megabytes of a photo. A
  /// re-check, because a session row can be minutes old.
  attachmentBegin(
    'attachment.begin',
    origin: FrameOrigin.companion,
    capability: Capability.sendAttachment,
  ),

  /// One slice of the file, base64 in the envelope, answered before the next is
  /// sent. Answered one at a time because the outbound queue drops its
  /// **oldest** frame on overflow: an unacknowledged chunk did not land.
  attachmentChunk(
    'attachment.chunk',
    origin: FrameOrigin.companion,
    capability: Capability.sendAttachment,
  ),

  /// Every agent account's usage limits, as the desktop last read them —
  /// asked when the phone's Usage view opens, never pushed.
  usageGet(
    'usage.get',
    origin: FrameOrigin.companion,
    capability: Capability.viewUsage,
  ),

  /// The desktop's notes and todo list, read-only — asked when the phone's
  /// Notes view opens, never pushed. Gated like the session list: a new bit
  /// would refuse every phone already paired.
  notesGet(
    'notes.get',
    origin: FrameOrigin.companion,
    capability: Capability.viewSessions,
  ),

  /// The models and permission modes a session can be put on, and which it is
  /// on. Gated like the list it is read from.
  sessionOptions(
    'session.options',
    origin: FrameOrigin.companion,
    capability: Capability.viewSessions,
  ),

  /// Puts a session on a model or permission mode, live where the agent allows
  /// it. Gated on [Capability.sendPrompt]: it acts on the agent as a prompt
  /// does, and a new bit would refuse every phone already paired.
  sessionConfigure(
    'session.configure',
    origin: FrameOrigin.companion,
    capability: Capability.sendPrompt,
  ),

  /// The phone rendered every host frame up to `p.seq`, and whether it is
  /// `p.watching`. No capability: it is about the phone's own stream, and a
  /// bit would exclude every phone already paired. Never answered.
  streamAck('stream.ack', origin: FrameOrigin.companion),

  /// Proof of life on an idle link: answered with an empty `result`. A host
  /// that predates it answers `unknown_type`, which is proof enough, and the
  /// host starts its own silence deadline only once a phone has pinged.
  linkPing('link.ping', origin: FrameOrigin.companion),

  /// Switch this sealed channel to the host protocol (slice 5e): once
  /// answered, every sealed frame either way carries host-protocol bytes, and
  /// the server serves this link as a desktop client. [Capability.phoneClient]
  /// attaches too (`CapabilitySet.allows`), at the phone tier.
  hostAttach(
    'host.attach',
    origin: FrameOrigin.companion,
    capability: Capability.desktopClient,
  ),

  /// Takes back a switched link whose socket dropped (Stage 0 step 16):
  /// `p.lastReceived`, the last host sequence this end took in order, and
  /// `p.skip`, its earlier resume frames that may not have landed. Valid only
  /// as the first sealed frame on a new socket, after a `LinkHello` with
  /// `resume`, while the server holds the link suspended. Answered with a
  /// `result` of the same `id` — `{resumed: true, lastReceived, skip}` for the
  /// server's side — then the server sends again whatever came after
  /// `p.lastReceived`. Refused with an `error`, and the link ends. No
  /// capability: `host.attach` already required an attach tier.
  linkResume('link.resume', origin: FrameOrigin.companion),

  sessionChanged('session.changed', origin: FrameOrigin.host),
  transcriptAppended('transcript.appended', origin: FrameOrigin.host),
  approvalRequested('approval.requested', origin: FrameOrigin.host),

  /// That approval is no longer waiting — for whatever reason. Without it, a
  /// request answered anywhere else left the phone's card orphaned and
  /// actionable, and silence reads like a desktop that is merely busy.
  approvalResolved('approval.resolved', origin: FrameOrigin.host),
  hostStatus('host.status', origin: FrameOrigin.host),

  /// The host has revoked this pairing; nothing more will be answered. Over a
  /// relay the phone's socket survives the revoke, so silence would otherwise
  /// be indistinguishable from a busy desktop.
  pairingRevoked('pairing.revoked', origin: FrameOrigin.host),

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

  /// Frames that act on an agent, and so carry `p.inputSeq`: one arriving
  /// after a later one would type into somebody's agent out of order.
  bool get isInput => switch (this) {
    promptSend || approvalAnswer || questionAnswer || menuAnswer => true,
    _ => false,
  };

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
  internal('internal'),

  /// The phone stopped acking the stream; nothing more is pushed until it acks
  /// again, and then it is sent current state, never what it missed.
  streamStalled('stream_stalled'),

  /// An input frame arrived out of order; `p.expected` is the sequence the
  /// host wants next, so the phone can realign.
  outOfOrder('out_of_order');

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

  static const int lengthInBytes = kRendezvousIdBytes;

  /// What the relay accepts as a path segment.
  static final RegExp pattern = rendezvousIdPattern;

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

/// The one JSON envelope carried inside every sealed frame. `seq` is the
/// sender's per-direction frame number, stamped again inside the sealed payload
/// so a receiver can check the two agree.
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

/// Raw bytes carried by one `attachment.chunk`, sized backwards from
/// [kMaxEnvelopeBytes]: base64 costs four characters per three bytes, and the
/// envelope and the seal add their own. Deliberately conservative — a frame
/// occupying most of an envelope is the shape that starved this link before.
const int kAttachmentChunkBytes = 128 * 1024;

/// The largest file one attachment will carry — the same number
/// `kMaxSessionMediaBytes` uses, so a file the phone can send is one the
/// desktop's own media surfaces can already draw. It is 96 chunks.
const int kMaxAttachmentBytes = 12 * 1024 * 1024;

/// The most messages one `transcript.get` will carry. **Every** page is bounded
/// by it, including one asked for with `after`: a resume from a cursor used to
/// answer with the whole remainder, which no link could carry. A page that
/// could not carry everything says so with `hasNewer`.
const int kRemoteTranscriptPageMax = 300;
