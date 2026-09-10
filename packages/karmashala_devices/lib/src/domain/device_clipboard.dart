/// One reading of a device's clipboard, and what a write to it produced.
///
/// A clipboard that could not be read is **not** an empty clipboard: on Android
/// `getPrimaryClip` answers `null` both when nothing has been copied and when
/// the caller may not look. So there are three outcomes, never two, and
/// [DeviceClipboardRead] cannot be constructed without choosing one.
library;

/// Which of the three answers a read produced.
enum DeviceClipboardOutcome {
  /// The device answered, with something on it.
  text,

  /// The device answered, and its clipboard is empty. A *measurement*, not a
  /// fallback for a read that did not happen.
  empty,

  /// The device did not answer, or could not be asked. Carries
  /// [DeviceClipboardRead.reason].
  unavailable,
}

/// How a reading was obtained, because it changes what its age means.
enum DeviceClipboardSource {
  /// Asked for, and answered. As fresh as the round trip.
  requested,

  /// The device volunteered it: scrcpy-server pushes the clipboard whenever it
  /// changes. An event, not a poll — but as old as the last copy on the phone.
  pushedByDevice,

  /// Nobody has asked and the device has volunteered nothing. The state the
  /// pane opens in, and the one thing that must not read as "empty".
  none,
}

/// What a device's clipboard was, when that was established, and how.
class DeviceClipboardRead {
  const DeviceClipboardRead._({
    required this.outcome,
    required this.source,
    required this.observedAt,
    this.text,
    this.reason,
  });

  /// The device answered with [text]. An empty string is routed to [empty]: the
  /// two mean the same thing to the device and one of them is easier to say.
  factory DeviceClipboardRead.text(
    String text, {
    required DeviceClipboardSource source,
    DateTime? observedAt,
  }) => text.isEmpty
      ? DeviceClipboardRead.empty(source: source, observedAt: observedAt)
      : DeviceClipboardRead._(
          outcome: DeviceClipboardOutcome.text,
          source: source,
          observedAt: observedAt ?? DateTime.now().toUtc(),
          text: text,
        );

  /// The device answered, and there is nothing on its clipboard. Only ever built
  /// from an answer; a timeout, a closed socket or a refusal is [unavailable].
  factory DeviceClipboardRead.empty({
    required DeviceClipboardSource source,
    DateTime? observedAt,
  }) => DeviceClipboardRead._(
    outcome: DeviceClipboardOutcome.empty,
    source: source,
    observedAt: observedAt ?? DateTime.now().toUtc(),
  );

  /// The clipboard could not be read, and [reason] says why in the user's
  /// terms. No [source], because nothing was observed.
  factory DeviceClipboardRead.unavailable(
    String reason, {
    DateTime? observedAt,
  }) => DeviceClipboardRead._(
    outcome: DeviceClipboardOutcome.unavailable,
    source: DeviceClipboardSource.none,
    observedAt: observedAt ?? DateTime.now().toUtc(),
    reason: reason,
  );

  /// Nothing has been read yet. The pane needs something to draw before the
  /// first read, and what it draws must not be a claim about the device.
  static final DeviceClipboardRead unchecked = DeviceClipboardRead._(
    outcome: DeviceClipboardOutcome.unavailable,
    source: DeviceClipboardSource.none,
    observedAt: DateTime.utc(1970),
    reason: 'The device has not been asked for its clipboard yet.',
  );

  final DeviceClipboardOutcome outcome;
  final DeviceClipboardSource source;

  /// When this was established, UTC. Rendered with `describeAge` — a reading
  /// with no age is a claim about now, which it usually is not.
  final DateTime observedAt;

  /// The clipboard's contents, non-null exactly when [outcome] is
  /// [DeviceClipboardOutcome.text]. **User data:** never logged, never in a
  /// [DeviceAction] summary, never in an error message.
  final String? text;

  /// Why the clipboard could not be read. Non-null exactly when [outcome] is
  /// [DeviceClipboardOutcome.unavailable].
  final String? reason;

  bool get hasText => outcome == DeviceClipboardOutcome.text;

  /// Whether this reading says anything about the device at all.
  bool get wasObserved => outcome != DeviceClipboardOutcome.unavailable;

  /// The one line a pane shows. Never includes [text] — that goes to the host
  /// clipboard, not to a label.
  String get summary => switch (outcome) {
    DeviceClipboardOutcome.text =>
      '${text!.length} character${text!.length == 1 ? '' : 's'} on the '
          "device's clipboard",
    DeviceClipboardOutcome.empty => "The device's clipboard is empty",
    DeviceClipboardOutcome.unavailable => reason!,
  };

  @override
  String toString() => 'DeviceClipboardRead(${outcome.name}, ${source.name})';
}

/// What a write to a device's clipboard produced.
enum DeviceClipboardWriteOutcome {
  /// The device acknowledged it. The clipboard is what was sent.
  acknowledged,

  /// It was sent and nothing came back. **Its own outcome, not a failure and not
  /// a success:** the bytes left this machine, and what the device did with them
  /// is unknown.
  unacknowledged,

  /// It never left: no control socket, or nothing to send.
  refused,
}

/// The result of putting text on a device's clipboard.
class DeviceClipboardWrite {
  const DeviceClipboardWrite._(this.outcome, this.detail);

  const DeviceClipboardWrite.acknowledged()
    : this._(
        DeviceClipboardWriteOutcome.acknowledged,
        "Copied to the device's clipboard.",
      );

  const DeviceClipboardWrite.unacknowledged(String detail)
    : this._(DeviceClipboardWriteOutcome.unacknowledged, detail);

  const DeviceClipboardWrite.refused(String detail)
    : this._(DeviceClipboardWriteOutcome.refused, detail);

  final DeviceClipboardWriteOutcome outcome;

  /// One line for the user. Never contains the text that was sent.
  final String detail;

  bool get isAcknowledged =>
      outcome == DeviceClipboardWriteOutcome.acknowledged;

  @override
  String toString() => 'DeviceClipboardWrite(${outcome.name})';
}
