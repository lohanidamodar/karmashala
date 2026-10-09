/// Who a launch is for: a person's own start, resume or message goes first;
/// automations, webhooks, scheduled resumes and agents' sub-sessions wait.
enum LaunchPriority {
  interactive,
  background;

  static LaunchPriority parse(Object? name) =>
      name == background.name ? background : interactive;
}

/// What a limit counts against.
enum CapacityScope {
  global,
  machine,
  account,
  project;

  static CapacityScope? parse(Object? name) {
    for (final scope in values) {
      if (scope.name == name) return scope;
    }
    return null;
  }
}

/// The key Settings keep the limits under, inside `settings.v1`.
const String kLaunchLimitsSettingsKey = 'launchLimits';

/// The one rule for what holds a slot, as Settings shows it.
const String kLaunchSlotRule =
    'A session holds a slot while its agent is working, asking or waiting '
    'for you, or while its state is unknown. One that has finished its turn '
    'and sits idle does not.';

/// A person's concurrency limits. Every limit is optional and a whole number
/// of at least one; nothing set is no limit at all.
final class LaunchLimits {
  const LaunchLimits({
    this.global,
    this.machines = const {},
    this.accounts = const {},
    this.projects = const {},
    this.pauseBackground = false,
    this.holdBackgroundAbovePercent,
  });

  static const LaunchLimits none = LaunchLimits();

  final int? global;

  /// Per environment id (`windows`, a WSL distribution, an SSH host).
  final Map<String, int> machines;

  /// Per usage account key (`agentId@environmentId`).
  final Map<String, int> accounts;

  /// Per project id.
  final Map<String, int> projects;

  /// New background work waits; running sessions are untouched.
  final bool pauseBackground;

  /// Background work waits while its account's 5-hour window is above this
  /// percent. An unknown reading never holds.
  final int? holdBackgroundAbovePercent;

  bool get hasLimits =>
      global != null ||
      machines.isNotEmpty ||
      accounts.isNotEmpty ||
      projects.isNotEmpty;

  int? limitOf(CapacityScope scope, String key) => switch (scope) {
    CapacityScope.global => global,
    CapacityScope.machine => machines[key],
    CapacityScope.account => accounts[key],
    CapacityScope.project => projects[key],
  };

  LaunchLimits copyWith({
    int? Function()? global,
    Map<String, int>? machines,
    Map<String, int>? accounts,
    Map<String, int>? projects,
    bool? pauseBackground,
    int? Function()? holdBackgroundAbovePercent,
  }) => LaunchLimits(
    global: global == null ? this.global : global(),
    machines: machines ?? this.machines,
    accounts: accounts ?? this.accounts,
    projects: projects ?? this.projects,
    pauseBackground: pauseBackground ?? this.pauseBackground,
    holdBackgroundAbovePercent: holdBackgroundAbovePercent == null
        ? this.holdBackgroundAbovePercent
        : holdBackgroundAbovePercent(),
  );

  Map<String, Object?> toJson() => {
    if (global != null) 'global': global,
    if (machines.isNotEmpty) 'machines': machines,
    if (accounts.isNotEmpty) 'accounts': accounts,
    if (projects.isNotEmpty) 'projects': projects,
    if (pauseBackground) 'pauseBackground': true,
    if (holdBackgroundAbovePercent != null)
      'holdBackgroundAbovePercent': holdBackgroundAbovePercent,
  };

  /// [json] as Settings wrote it; anything unreadable is unset.
  static LaunchLimits fromJson(Object? json) {
    if (json is! Map) return none;
    int? count(Object? value) => value is int && value >= 1 ? value : null;
    Map<String, int> counts(Object? value) => {
      if (value is Map)
        for (final entry in value.entries)
          if (entry.key is String && count(entry.value) != null)
            entry.key as String: entry.value as int,
    };
    final hold = json['holdBackgroundAbovePercent'];
    return LaunchLimits(
      global: count(json['global']),
      machines: counts(json['machines']),
      accounts: counts(json['accounts']),
      projects: counts(json['projects']),
      pauseBackground: json['pauseBackground'] == true,
      holdBackgroundAbovePercent: hold is int && hold >= 1 && hold <= 100
          ? hold
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LaunchLimits &&
      other.global == global &&
      _sameCounts(other.machines, machines) &&
      _sameCounts(other.accounts, accounts) &&
      _sameCounts(other.projects, projects) &&
      other.pauseBackground == pauseBackground &&
      other.holdBackgroundAbovePercent == holdBackgroundAbovePercent;

  @override
  int get hashCode => Object.hash(
    global,
    machines.length,
    accounts.length,
    projects.length,
    pauseBackground,
    holdBackgroundAbovePercent,
  );
}

bool _sameCounts(Map<String, int> a, Map<String, int> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

/// How full one limited scope is.
final class CapacityScopeUse {
  const CapacityScopeUse({
    required this.scope,
    required this.key,
    required this.label,
    required this.used,
    required this.limit,
    this.holders = const [],
  });

  final CapacityScope scope;
  final String key;

  /// The scope in a person's words: "WSL · archlinux", a project's name.
  final String label;
  final int used;
  final int limit;

  /// The titles of the sessions holding its slots.
  final List<String> holders;

  bool get isFull => used >= limit;

  Map<String, Object?> toJson() => {
    'scope': scope.name,
    'key': key,
    'label': label,
    'used': used,
    'limit': limit,
    if (holders.isNotEmpty) 'holders': holders,
  };

  static CapacityScopeUse fromJson(Map<String, Object?> json) =>
      CapacityScopeUse(
        scope: CapacityScope.parse(json['scope']) ?? CapacityScope.global,
        key: json['key'] as String? ?? '',
        label: json['label'] as String? ?? '',
        used: json['used'] as int? ?? 0,
        limit: json['limit'] as int? ?? 0,
        holders: [
          for (final holder in json['holders'] as List? ?? const [])
            if (holder is String) holder,
        ],
      );
}

/// A launch waiting for a slot, with why and where it is in line.
final class LaunchWaiter {
  const LaunchWaiter({
    required this.ticketId,
    required this.label,
    required this.priority,
    required this.place,
    required this.reason,
    required this.enqueuedAt,
    this.sessionId,
    this.personStarted = false,
  });

  final String ticketId;
  final String label;
  final String? sessionId;
  final LaunchPriority priority;

  /// One-based place in line, interactive waiters first.
  final int place;

  /// "Waiting for a slot: 2 of 2 on WSL · archlinux are busy (X, Y)".
  final String reason;
  final DateTime enqueuedAt;

  /// A person started it, so it may be started anyway and is in the inbox.
  final bool personStarted;

  Map<String, Object?> toJson() => {
    'ticketId': ticketId,
    'label': label,
    if (sessionId != null) 'sessionId': sessionId,
    'priority': priority.name,
    'place': place,
    'reason': reason,
    'enqueuedAt': enqueuedAt.toUtc().toIso8601String(),
    if (personStarted) 'personStarted': true,
  };

  static LaunchWaiter fromJson(Map<String, Object?> json) => LaunchWaiter(
    ticketId: json['ticketId'] as String? ?? '',
    label: json['label'] as String? ?? '',
    sessionId: json['sessionId'] as String?,
    priority: LaunchPriority.parse(json['priority']),
    place: json['place'] as int? ?? 0,
    reason: json['reason'] as String? ?? '',
    enqueuedAt:
        DateTime.tryParse(json['enqueuedAt'] as String? ?? '')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    personStarted: json['personStarted'] == true,
  );
}

/// The limits, how full each limited scope is, and who is waiting.
final class CapacitySnapshot {
  const CapacitySnapshot({
    this.limits = LaunchLimits.none,
    this.running = 0,
    this.scopes = const [],
    this.waiters = const [],
  });

  static const CapacitySnapshot empty = CapacitySnapshot();

  final LaunchLimits limits;

  /// Sessions holding a slot now, by [kLaunchSlotRule].
  final int running;
  final List<CapacityScopeUse> scopes;
  final List<LaunchWaiter> waiters;

  LaunchWaiter? waiterFor(String sessionId) {
    for (final waiter in waiters) {
      if (waiter.sessionId == sessionId) return waiter;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'limits': limits.toJson(),
    'running': running,
    'scopes': [for (final scope in scopes) scope.toJson()],
    'waiters': [for (final waiter in waiters) waiter.toJson()],
  };

  static CapacitySnapshot fromJson(Map<String, Object?> json) =>
      CapacitySnapshot(
        limits: LaunchLimits.fromJson(json['limits']),
        running: json['running'] as int? ?? 0,
        scopes: [
          for (final scope in json['scopes'] as List? ?? const [])
            if (scope is Map)
              CapacityScopeUse.fromJson(scope.cast<String, Object?>()),
        ],
        waiters: [
          for (final waiter in json['waiters'] as List? ?? const [])
            if (waiter is Map)
              LaunchWaiter.fromJson(waiter.cast<String, Object?>()),
        ],
      );
}

/// Said with a start that did not start yet: it waits for a slot and will
/// start by itself.
final class SessionWait {
  const SessionWait({
    required this.ticketId,
    required this.reason,
    required this.place,
  });

  final String ticketId;
  final String reason;
  final int place;

  Map<String, Object?> toJson() => {
    'ticketId': ticketId,
    'reason': reason,
    'place': place,
  };

  static SessionWait fromJson(Map<String, Object?> json) => SessionWait(
    ticketId: json['ticketId'] as String? ?? '',
    reason: json['reason'] as String? ?? '',
    place: json['place'] as int? ?? 0,
  );
}
