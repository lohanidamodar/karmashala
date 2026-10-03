/// What happens when a session's turn ends on a usage limit.
enum UsageLimitBehavior {
  /// Arm a resume at the reset without asking, where the unattended rules allow.
  schedule('Resume automatically at the reset'),

  /// Say so in the session, and offer to resume at the reset.
  ask('Ask first'),

  /// Leave it alone.
  nothing('Do nothing');

  const UsageLimitBehavior(this.label);

  final String label;

  static UsageLimitBehavior fromName(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return UsageLimitBehavior.schedule;
  }

  /// Reads the choice out of `settings.v1`'s JSON. The legacy key was written
  /// on every save while `ask` was the default, so a stored `ask` there was
  /// almost never chosen: it reads as the new default. The server reads the
  /// same keys the same way (`usageLimitSettingsFrom`).
  static UsageLimitBehavior fromSettingsJson(Map<String, Object?> json) {
    if (json.containsKey(kUsageLimitSettingKey)) {
      return fromName(json[kUsageLimitSettingKey]);
    }
    return json[kLegacyUsageLimitSettingKey] == UsageLimitBehavior.nothing.name
        ? UsageLimitBehavior.nothing
        : UsageLimitBehavior.schedule;
  }
}

/// Where `settings.v1` keeps [UsageLimitBehavior].
const String kUsageLimitSettingKey = 'onUsageLimit';

/// Where it was kept while `ask` was the default; read, never written.
const String kLegacyUsageLimitSettingKey = 'usageLimitBehavior';

/// What a scheduled resume says unless the user typed something else.
const String kDefaultResumeMessage = 'continue';
