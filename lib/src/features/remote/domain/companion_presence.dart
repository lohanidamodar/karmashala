/// What a companion says about itself, so a notification can be **routed**.
///
/// **Presence routes notifications and never gates delivery.** The polarity is
/// the whole safety of it, and `push_fanout.dart` is the only file that spends
/// this value: a reading here can turn a suppressed push back into a sent one,
/// and nothing on the live stream may read it at all. A stale reading therefore
/// costs at most a duplicate notification, where the same reading on the
/// delivery path would cost a turn nobody ever sees —
/// `presence_is_not_delivery_test.dart` holds that line.
///
/// **Every unknown behaves exactly as a phone did before this frame existed.**
/// An old companion sends none of these fields, they decode to their own
/// `unknown`, and the routing rule falls back to "a live link suppresses a
/// push" — today's behaviour, unchanged, for a build that cannot say otherwise.
library;

/// What kind of thing the companion is running on.
///
/// Carried rather than spent: the routing rule below turns on visibility and
/// focus, and a kind nobody reads is honest where a kind guessed from the push
/// platform would not be. It is on the wire because the question the rule asks
/// next is about it.
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

  /// The additive half of a `notifications.register` payload.
  ///
  /// **A field with nothing to say is absent**, never a word meaning unknown:
  /// a companion that reports nothing sends exactly the bytes it always sent,
  /// which is what keeps an old host reading a new phone's frame.
  Map<String, Object?> toRegisterFields() => <String, Object?>{
    if (deviceKind != CompanionDeviceKind.unknown) 'deviceKind': deviceKind.wire,
    if (visibility != CompanionVisibility.unknown)
      'visibility': visibility.wire,
    if (focusedSessionId != null && focusedSessionId!.isNotEmpty)
      'focusedSessionId': focusedSessionId,
  };

  /// Reads the additive fields out of a `notifications.register` payload.
  ///
  /// Never throws and never refuses the frame: a wrongly typed field degrades
  /// to its own unknown, exactly as `payload_compat_test.dart` requires of
  /// every additive field in this protocol.
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

  /// Whether this says the same thing as [other], ignoring when it was said.
  ///
  /// What "one frame per change" is decided by: a companion re-reporting the
  /// same presence sends nothing, so the frame count follows changes rather
  /// than a clock.
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

/// Whether a push to a phone with a live link should be **suppressed**.
///
/// The one place presence is turned into a decision, kept here so the rule can
/// be read in one piece and tested without a relay.
///
/// * A phone that says nothing is suppressed — that is what happened before
///   this frame existed, and an old companion must not change behaviour.
/// * A **backgrounded** phone is not suppressed: it hears the stream event
///   into a window nobody can see, which is the reported failure.
/// * A **foreground** phone is suppressed unless it has positively named a
///   different session as the one on its screen. Only a reading that says
///   "this news is not what I am looking at" turns a suppression into a push;
///   every silence falls on the suppressing side.
bool presenceSuppressesPush(CompanionPresence presence, String sessionId) =>
    switch (presence.visibility) {
      CompanionVisibility.unknown => true,
      CompanionVisibility.background => false,
      CompanionVisibility.foreground =>
        presence.focusedSessionId == null ||
            presence.focusedSessionId == sessionId,
    };
