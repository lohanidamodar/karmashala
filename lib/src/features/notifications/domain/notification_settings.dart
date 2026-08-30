/// User preferences for agent status notifications.
///
/// Stored separately from `Settings` under its own metadata key, following the
/// same repository-over-`app_metadata` pattern. The defaults are deliberately
/// restrained: notifications are on, but only ever fire while the window is
/// unfocused, so a first run cannot interrupt someone who is already looking at
/// the app.
class NotificationSettings {
  const NotificationSettings({
    this.enabled = true,
    this.onlyWhenUnfocused = true,
    this.notifyWhenFinished = true,
    this.notifyWhenAttentionNeeded = true,
  });

  /// Master switch. When false nothing is ever delivered, though the tray still
  /// shows what needs attention — an icon is ambient, a toast is an interrupt.
  final bool enabled;

  /// Only deliver while the app window does not have OS focus.
  final bool onlyWhenUnfocused;

  /// Notify when an agent stops working (a turn finished).
  final bool notifyWhenFinished;

  /// Notify when an agent is waiting for approval or has failed.
  final bool notifyWhenAttentionNeeded;

  NotificationSettings copyWith({
    bool? enabled,
    bool? onlyWhenUnfocused,
    bool? notifyWhenFinished,
    bool? notifyWhenAttentionNeeded,
  }) => NotificationSettings(
    enabled: enabled ?? this.enabled,
    onlyWhenUnfocused: onlyWhenUnfocused ?? this.onlyWhenUnfocused,
    notifyWhenFinished: notifyWhenFinished ?? this.notifyWhenFinished,
    notifyWhenAttentionNeeded:
        notifyWhenAttentionNeeded ?? this.notifyWhenAttentionNeeded,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'onlyWhenUnfocused': onlyWhenUnfocused,
    'notifyWhenFinished': notifyWhenFinished,
    'notifyWhenAttentionNeeded': notifyWhenAttentionNeeded,
  };

  /// Reads [json], falling back to the default for any absent or malformed
  /// field so a hand-edited or older record still loads.
  static NotificationSettings fromJson(Map<String, dynamic> json) {
    bool flag(String key, {required bool orElse}) =>
        json[key] is bool ? json[key] as bool : orElse;
    return NotificationSettings(
      enabled: flag('enabled', orElse: true),
      onlyWhenUnfocused: flag('onlyWhenUnfocused', orElse: true),
      notifyWhenFinished: flag('notifyWhenFinished', orElse: true),
      notifyWhenAttentionNeeded: flag(
        'notifyWhenAttentionNeeded',
        orElse: true,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NotificationSettings &&
      other.enabled == enabled &&
      other.onlyWhenUnfocused == onlyWhenUnfocused &&
      other.notifyWhenFinished == notifyWhenFinished &&
      other.notifyWhenAttentionNeeded == notifyWhenAttentionNeeded;

  @override
  int get hashCode => Object.hash(
    enabled,
    onlyWhenUnfocused,
    notifyWhenFinished,
    notifyWhenAttentionNeeded,
  );
}
