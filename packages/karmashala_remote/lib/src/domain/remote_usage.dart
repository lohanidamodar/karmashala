/// An agent account's usage limits as the desktop read them — what
/// `usage.get` answers. Only percentages exist (no agent reports a used/limit
/// pair), each reading carries its own time, and a window the desktop could
/// not read is said to be unread rather than drawn as empty.
library;

/// How a window is being spent, as the desktop judged it from one reading.
enum RemoteUsagePace {
  /// No span, reset or percent to judge by — said as nothing.
  unknown('unknown'),
  onPace('on_pace'),
  aheadOfPace('ahead'),
  overPace('over'),
  spent('spent');

  const RemoteUsagePace(this.wire);

  final String wire;

  static RemoteUsagePace parse(Object? wire) =>
      values.where((p) => p.wire == wire).firstOrNull ??
      RemoteUsagePace.unknown;
}

/// One point of a window's history.
class RemoteUsageSample {
  const RemoteUsageSample({required this.at, required this.percent});

  final DateTime at;
  final double percent;

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'p': percent,
  };

  static RemoteUsageSample? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final at = DateTime.tryParse('${json['at']}');
    final percent = json['p'];
    if (at == null || percent is! num) return null;
    return RemoteUsageSample(at: at.toUtc(), percent: percent.toDouble());
  }
}

/// One limit window of one account.
class RemoteUsageWindow {
  const RemoteUsageWindow({
    required this.label,
    this.percent,
    this.resetsAt,
    this.span,
    this.pace = RemoteUsagePace.unknown,
    this.limitAt,
    this.samples = const [],
  });

  /// The agent's own name for it: `5-hour`, `7-day`, `Opus · 7-day`.
  final String label;

  /// Null when the agent named the window but gave no percentage.
  final double? percent;
  final DateTime? resetsAt;
  final Duration? span;
  final RemoteUsagePace pace;

  /// When the current rate reaches the limit, for [RemoteUsagePace.overPace].
  final DateTime? limitAt;

  /// The last day of readings, oldest first, thinned for the wire.
  final List<RemoteUsageSample> samples;

  Map<String, Object?> toJson() => {
    'label': label,
    'percent': ?percent,
    if (resetsAt != null) 'resetsAt': resetsAt!.toUtc().toIso8601String(),
    if (span != null) 'spanSeconds': span!.inSeconds,
    if (pace != RemoteUsagePace.unknown) 'pace': pace.wire,
    if (limitAt != null) 'limitAt': limitAt!.toUtc().toIso8601String(),
    if (samples.isNotEmpty) 'samples': [for (final s in samples) s.toJson()],
  };

  static RemoteUsageWindow? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final label = json['label'];
    if (label is! String || label.isEmpty) return null;
    final percent = json['percent'];
    final span = json['spanSeconds'];
    final samples = json['samples'];
    return RemoteUsageWindow(
      label: label,
      percent: percent is num ? percent.toDouble() : null,
      resetsAt: DateTime.tryParse('${json['resetsAt']}')?.toUtc(),
      span: span is int ? Duration(seconds: span) : null,
      pace: RemoteUsagePace.parse(json['pace']),
      limitAt: DateTime.tryParse('${json['limitAt']}')?.toUtc(),
      samples: [
        if (samples is List)
          for (final s in samples) ?RemoteUsageSample.tryFromJson(s),
      ],
    );
  }
}

/// One agent account: an agent signed in on one machine of the desktop's.
class RemoteUsageAccount {
  const RemoteUsageAccount({
    required this.key,
    required this.agentId,
    required this.agentName,
    required this.environment,
    this.email,
    this.readAt,
    this.windows = const [],
    this.failure,
  });

  /// `agentId@environmentId` — two installs of one CLI in one place share it.
  final String key;
  final String agentId;
  final String agentName;

  /// Which machine: "Windows", "WSL · archlinux".
  final String environment;
  final String? email;

  /// When the windows were read; null when they never were.
  final DateTime? readAt;
  final List<RemoteUsageWindow> windows;

  /// Why no fresh reading came — rate-limited, signed out — in words.
  final String? failure;

  Map<String, Object?> toJson() => {
    'key': key,
    'agentId': agentId,
    'agentName': agentName,
    'environment': environment,
    'email': ?email,
    if (readAt != null) 'readAt': readAt!.toUtc().toIso8601String(),
    'windows': [for (final w in windows) w.toJson()],
    'failure': ?failure,
  };

  static RemoteUsageAccount? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final key = json['key'];
    final agentId = json['agentId'];
    if (key is! String || agentId is! String) return null;
    final windows = json['windows'];
    String? text(String name) =>
        json[name] is String ? json[name] as String : null;
    return RemoteUsageAccount(
      key: key,
      agentId: agentId,
      agentName: text('agentName') ?? agentId,
      environment: text('environment') ?? '',
      email: text('email'),
      readAt: DateTime.tryParse('${json['readAt']}')?.toUtc(),
      windows: [
        if (windows is List)
          for (final w in windows) ?RemoteUsageWindow.tryFromJson(w),
      ],
      failure: text('failure'),
    );
  }
}

/// What `usage.get` answers.
class RemoteUsageSnapshot {
  const RemoteUsageSnapshot({required this.accounts, required this.observedAt});

  final List<RemoteUsageAccount> accounts;

  /// The host's clock when it answered, so "resets in" is counted from the
  /// same instant on both ends.
  final DateTime observedAt;

  Map<String, Object?> toJson() => {
    'accounts': [for (final a in accounts) a.toJson()],
    'observedAt': observedAt.toUtc().toIso8601String(),
  };

  static RemoteUsageSnapshot fromJson(Map<String, Object?> json) {
    final accounts = json['accounts'];
    return RemoteUsageSnapshot(
      accounts: [
        if (accounts is List)
          for (final a in accounts) ?RemoteUsageAccount.tryFromJson(a),
      ],
      observedAt:
          DateTime.tryParse('${json['observedAt']}')?.toUtc() ??
          DateTime.now().toUtc(),
    );
  }
}
