/// What a companion says about itself, so a notification can be **routed**.
///
/// **Presence routes notifications and never gates delivery.** Only
/// `push_fanout.dart` spends it, so a stale reading costs at most a duplicate
/// notification. Every unknown behaves exactly as a phone did before this frame
/// existed.
library;

/// What kind of thing the companion is running on. Carried rather than spent:
/// a kind nobody reads is honest where one guessed from the push platform
/// would not be.
enum CompanionDeviceKind {
  phone('phone'),
  tablet('tablet'),
  desktop('desktop'),

  /// Nothing was said. An old companion, and the default.
  unknown('unknown');

  const CompanionDeviceKind(this.wire);

  final String wire;

  /// An absent or unrecognised word reads as [unknown] — the same rule
  /// `RemoteWaitKind.parse` follows, for the same reason: a word this build
  /// has never heard is not a licence to guess.
  static CompanionDeviceKind parse(Object? wire) =>
      _byWire[wire] ?? CompanionDeviceKind.unknown;

  static final Map<Object?, CompanionDeviceKind> _byWire = {
    for (final kind in CompanionDeviceKind.values) kind.wire: kind,
  };
}

/// Whether the companion is on screen.
enum CompanionVisibility {
  /// The app is in front of its owner.
  foreground('foreground'),

  /// Connected, but nobody can see it — the case this whole frame exists for.
  background('background'),

  /// Nothing was said.
  unknown('unknown');

  const CompanionVisibility(this.wire);

  final String wire;

  static CompanionVisibility parse(Object? wire) =>
      _byWire[wire] ?? CompanionVisibility.unknown;

  static final Map<Object?, CompanionVisibility> _byWire = {
    for (final value in CompanionVisibility.values) value.wire: value,
  };
}

/// One phone's presence, as it last described itself.
class CompanionPresence {
  const CompanionPresence({
    this.deviceKind = CompanionDeviceKind.unknown,
    this.visibility = CompanionVisibility.unknown,
    this.focusedSessionId,
    this.at,
  });

  /// Nothing has been said — what an old companion's `notifications.register`
  /// decodes to, and what a device that has never registered reads as.
  static const CompanionPresence unknown = CompanionPresence();

  final CompanionDeviceKind deviceKind;
  final CompanionVisibility visibility;

  /// The session on the phone's screen, or null when it named none.
  final String? focusedSessionId;

  /// When the phone said it, or **null when nothing has been said** (§19). A
  /// reading with no time is not a reading.
  final DateTime? at;

  bool get isRecorded => at != null;

  /// The additive half of a `notifications.register` payload. **A field with
  /// nothing to say is absent**, never a word meaning unknown, so an old host
  /// still reads a new phone's frame.
  Map<String, Object?> toRegisterFields() => <String, Object?>{
    if (deviceKind != CompanionDeviceKind.unknown)
      'deviceKind': deviceKind.wire,
    if (visibility != CompanionVisibility.unknown)
      'visibility': visibility.wire,
    if (focusedSessionId != null && focusedSessionId!.isNotEmpty)
      'focusedSessionId': focusedSessionId,
  };

  /// Reads the additive fields out of a `notifications.register` payload. Never
  /// throws and never refuses the frame: a wrongly typed field degrades to its
  /// own unknown.
  static CompanionPresence fromRegister(
    Map<String, Object?> payload, {
    DateTime? at,
  }) => CompanionPresence(
    deviceKind: CompanionDeviceKind.parse(payload['deviceKind']),
    visibility: CompanionVisibility.parse(payload['visibility']),
    focusedSessionId: _text(payload['focusedSessionId']),
    at: at,
  );

  CompanionPresence copyWith({
    CompanionDeviceKind? deviceKind,
    CompanionVisibility? visibility,
    String? focusedSessionId,
    bool clearFocusedSession = false,
    DateTime? at,
  }) => CompanionPresence(
    deviceKind: deviceKind ?? this.deviceKind,
    visibility: visibility ?? this.visibility,
    focusedSessionId: clearFocusedSession
        ? null
        : focusedSessionId ?? this.focusedSessionId,
    at: at ?? this.at,
  );

  /// Whether this says the same thing as [other], ignoring when it was said —
  /// what "one frame per change" is decided by.
  bool saysSameAs(CompanionPresence other) =>
      deviceKind == other.deviceKind &&
      visibility == other.visibility &&
      focusedSessionId == other.focusedSessionId;

  @override
  String toString() =>
      'CompanionPresence(${deviceKind.wire}, ${visibility.wire}, '
      'focus=${focusedSessionId ?? '-'})';

  static String? _text(Object? value) =>
      value is String && value.isNotEmpty ? value : null;
}

/// Whether a push to a phone with a live link should be **suppressed** — the
/// one place presence is turned into a decision.
///
/// A phone that says nothing is suppressed, which is what happened before this
/// frame existed; a **backgrounded** phone is not; a **foreground** phone is,
/// unless it has positively named a different session. Every silence suppresses.
bool presenceSuppressesPush(CompanionPresence presence, String sessionId) =>
    switch (presence.visibility) {
      CompanionVisibility.unknown => true,
      CompanionVisibility.background => false,
      CompanionVisibility.foreground =>
        presence.focusedSessionId == null ||
            presence.focusedSessionId == sessionId,
    };
