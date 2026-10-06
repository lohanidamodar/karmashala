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

/// User preferences for agent status notifications. The defaults are restrained
/// on purpose: on, but only while the window is unfocused.
class NotificationSettings {
  const NotificationSettings({
    this.level = NotifyLevel.everything,
    this.onlyWhenUnfocused = true,
  });

  final NotifyLevel level;

  /// Only deliver while the app window does not have OS focus.
  final bool onlyWhenUnfocused;

  /// Whether anything may interrupt at all. When false the tray still shows
  /// what needs attention — an icon is ambient, a toast is an interrupt.
  bool get enabled => level != NotifyLevel.nothing;

  NotificationSettings copyWith({
    NotifyLevel? level,
    bool? onlyWhenUnfocused,
  }) => NotificationSettings(
    level: level ?? this.level,
    onlyWhenUnfocused: onlyWhenUnfocused ?? this.onlyWhenUnfocused,
  );

  /// The level, and the three switches it replaced, so an app from before
  /// levels reading this record behaves as near to it as its switches can.
  Map<String, dynamic> toJson() => {
    'level': level.name,
    'onlyWhenUnfocused': onlyWhenUnfocused,
    'enabled': enabled,
    'notifyWhenFinished': level == NotifyLevel.everything,
    'notifyWhenAttentionNeeded': enabled,
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
      other.onlyWhenUnfocused == onlyWhenUnfocused;

  @override
  int get hashCode => Object.hash(level, onlyWhenUnfocused);
}
