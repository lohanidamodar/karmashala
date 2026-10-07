/// How much an agent may interrupt the person: what "Notify me" is set to.
/// Whatever a level does not interrupt for is logged quietly — the inbox
/// still files it.
enum NotifyLevel {
  /// Every finished turn, ask, failure and delivery change.
  everything,

  /// Only what is stopped until the person acts — see
  /// `NotificationReason.interruptsAt`.
  whenNeeded,

  /// Never interrupt; the inbox and the tray still show what needs you.
  nothing,
}

/// What Focus replaced, to be put back when it ends: the level before it, and
/// whether sessions were hidden while working.
class FocusMemory {
  const FocusMemory({required this.level, required this.hideWorking});

  final NotifyLevel level;
  final bool hideWorking;

  Map<String, dynamic> toJson() => {
    'level': level.name,
    'hideWorking': hideWorking,
  };

  /// Null for anything but a whole record: a half-read Focus could only
  /// restore the wrong thing.
  static FocusMemory? fromJson(Object? json) {
    if (json is! Map) return null;
    final named = NotifyLevel.values.where((l) => l.name == json['level']);
    final hideWorking = json['hideWorking'];
    if (named.isEmpty || hideWorking is! bool) return null;
    return FocusMemory(level: named.single, hideWorking: hideWorking);
  }

  @override
  bool operator ==(Object other) =>
      other is FocusMemory &&
      other.level == level &&
      other.hideWorking == hideWorking;

  @override
  int get hashCode => Object.hash(level, hideWorking);
}

/// User preferences for agent status notifications. The defaults are restrained
/// on purpose: on, but only while the window is unfocused.
class NotificationSettings {
  const NotificationSettings({
    this.level = NotifyLevel.everything,
    this.onlyWhenUnfocused = true,
    this.focus,
    this.chime = false,
  });

  final NotifyLevel level;

  /// A soft sound once for each new thing that needs the person; off unless
  /// they turn it on.
  final bool chime;

  /// Only deliver while the app window does not have OS focus.
  final bool onlyWhenUnfocused;

  /// While Focus is on, what it replaced; null while it is off.
  final FocusMemory? focus;

  /// Whether anything may interrupt at all. When false the tray still shows
  /// what needs attention — an icon is ambient, a toast is an interrupt.
  bool get enabled => level != NotifyLevel.nothing;

  NotificationSettings copyWith({
    NotifyLevel? level,
    bool? onlyWhenUnfocused,
    FocusMemory? focus,
    bool endFocus = false,
    bool? chime,
  }) => NotificationSettings(
    level: level ?? this.level,
    onlyWhenUnfocused: onlyWhenUnfocused ?? this.onlyWhenUnfocused,
    focus: endFocus ? null : focus ?? this.focus,
    chime: chime ?? this.chime,
  );

  /// The level, and the three switches it replaced, so an app from before
  /// levels reading this record behaves as near to it as its switches can.
  Map<String, dynamic> toJson() => {
    'level': level.name,
    'onlyWhenUnfocused': onlyWhenUnfocused,
    'enabled': enabled,
    'notifyWhenFinished': level == NotifyLevel.everything,
    'notifyWhenAttentionNeeded': enabled,
    'focus': focus?.toJson(),
    'chime': chime,
  };

  /// Reads [json], falling back to the default for any absent or malformed
  /// field so a hand-edited or older record still loads. A record without a
  /// level — written before levels, or rewritten by an app from then — is
  /// read from its switches.
  static NotificationSettings fromJson(Map<String, dynamic> json) {
    bool flag(String key) => json[key] is bool ? json[key] as bool : true;
    final named = NotifyLevel.values.where((l) => l.name == json['level']);
    return NotificationSettings(
      level: named.isNotEmpty
          ? named.single
          : _levelFromSwitches(
              enabled: flag('enabled'),
              finished: flag('notifyWhenFinished'),
              attention: flag('notifyWhenAttentionNeeded'),
            ),
      onlyWhenUnfocused: flag('onlyWhenUnfocused'),
      focus: FocusMemory.fromJson(json['focus']),
      // Off unless written on: a sound is never turned on by a missing key.
      chime: json['chime'] == true,
    );
  }

  /// Finished on with attention off has no level of its own; it stays
  /// Everything, the nearest that still tells of a finished turn.
  static NotifyLevel _levelFromSwitches({
    required bool enabled,
    required bool finished,
    required bool attention,
  }) {
    if (!enabled || (!finished && !attention)) return NotifyLevel.nothing;
    if (!finished) return NotifyLevel.whenNeeded;
    return NotifyLevel.everything;
  }

  @override
  bool operator ==(Object other) =>
      other is NotificationSettings &&
      other.level == level &&
      other.onlyWhenUnfocused == onlyWhenUnfocused &&
      other.focus == focus &&
      other.chime == chime;

  @override
  int get hashCode => Object.hash(level, onlyWhenUnfocused, focus, chime);
}
