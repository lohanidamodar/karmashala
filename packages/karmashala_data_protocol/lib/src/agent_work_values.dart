import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_environments/karmashala_environments.dart';
import 'package:karmashala_projects/karmashala_projects.dart'
    show environmentPathFromJson, environmentPathToJson;

// What the server does for the agents on its machine (slice 2a) — usage, the
// signed-in account, detection and the CLI import — as the values it answers
// and tells. No credential is ever one of them.

/// One account's usage as the server last read it: the reading (however old;
/// its `fetchedAt` says), how the last attempt failed when it did, and when
/// the server asks next. An account is one agent in one environment
/// (`usageAccountKey`).
final class AccountUsageState {
  const AccountUsageState({
    required this.accountKey,
    required this.agentId,
    required this.environmentId,
    this.usage,
    this.failure,
    this.nextAt,
  });

  final String accountKey;
  final String agentId;
  final String environmentId;

  /// The last reading that came off the wire, or null before the first.
  final AgentUsage? usage;

  /// Why the latest attempt gave no reading; null when it did.
  final UsageFailure? failure;

  /// When the server's schedule asks next, when it has one.
  final DateTime? nextAt;

  Map<String, Object?> toJson() => {
    'accountKey': accountKey,
    'agentId': agentId,
    'environmentId': environmentId,
    if (usage != null) 'usage': agentUsageToJson(usage!),
    if (failure != null) 'failure': failure!.toJson(),
    if (nextAt != null) 'nextAt': _time(nextAt!),
  };

  static AccountUsageState fromJson(Map<String, Object?> json) =>
      AccountUsageState(
        accountKey: _string(json, 'accountKey'),
        agentId: _string(json, 'agentId'),
        environmentId: _string(json, 'environmentId'),
        usage: json['usage'] == null
            ? null
            : agentUsageFromJson(_object(json['usage'])),
        failure: json['failure'] == null
            ? null
            : UsageFailure.fromJson(_object(json['failure'])),
        nextAt: _optionalDate(json['nextAt']),
      );

  /// Same reading, same failure, same schedule — nothing to tell.
  bool sameAs(AccountUsageState other) =>
      toJson().toString() == other.toJson().toString();
}

/// How one usage attempt failed: the sentence, its kind, and — for a wait
/// the server is sitting out — when it asks again.
final class UsageFailure {
  const UsageFailure({required this.message, required this.kind, this.until});

  final String message;
  final UsageFailureKind kind;
  final DateTime? until;

  /// The exception a caller that asked for a reading is thrown, with the
  /// wait left at [now].
  UsageException toException(DateTime now) => UsageException(
    message,
    kind: kind,
    retryIn: until == null || !until!.isAfter(now)
        ? null
        : until!.difference(now),
  );

  Map<String, Object?> toJson() => {
    'message': message,
    'kind': kind.name,
    if (until != null) 'until': _time(until!),
  };

  static UsageFailure fromJson(Map<String, Object?> json) => UsageFailure(
    message: _string(json, 'message'),
    kind: _enum(UsageFailureKind.values, json['kind']),
    until: _optionalDate(json['until']),
  );
}

Map<String, Object?> agentUsageToJson(AgentUsage usage) => {
  'fetchedAt': _time(usage.fetchedAt),
  if (usage.email != null) 'email': usage.email,
  if (usage.tokenExpiresAt != null)
    'tokenExpiresAt': _time(usage.tokenExpiresAt!),
  'windows': [
    for (final window in usage.windows)
      {
        'label': window.label,
        if (window.percent != null) 'percent': window.percent,
        if (window.resetsAt != null) 'resetsAt': _time(window.resetsAt!),
        if (window.span != null) 'spanSeconds': window.span!.inSeconds,
      },
  ],
};

AgentUsage agentUsageFromJson(Map<String, Object?> json) => AgentUsage(
  fetchedAt: _date(json['fetchedAt']),
  email: _optional(json, 'email'),
  tokenExpiresAt: _optionalDate(json['tokenExpiresAt']),
  windows: [
    for (final item in _list(json['windows']))
      () {
        final window = _object(item);
        final percent = window['percent'];
        final span = window['spanSeconds'];
        if ((percent != null && percent is! num) ||
            (span != null && span is! int)) {
          throw const FormatException('not a usage window');
        }
        return UsageWindow(
          label: _string(window, 'label'),
          percent: (percent as num?)?.toDouble(),
          resetsAt: _optionalDate(window['resetsAt']),
          span: span == null ? null : Duration(seconds: span as int),
        );
      }(),
  ],
);

/// Who is signed in to one installation, read from its own files by the
/// server — **identity and expiry only**, never a token. Which shape answers
/// is the installation's accounts capability, not its agent.
sealed class AgentSignIn {
  const AgentSignIn();

  Map<String, Object?> toJson();

  static AgentSignIn fromJson(Map<String, Object?> json) =>
      switch (json['kind']) {
        'anthropicOAuth' => AnthropicSignIn.fromJson(json),
        'openAiAuthFile' => OpenAiSignIn.fromJson(json),
        'none' => const NoSignIn(),
        _ => throw const FormatException('not a sign-in'),
      };
}

/// An agent whose adapter offers no account switching.
final class NoSignIn extends AgentSignIn {
  const NoSignIn();

  @override
  Map<String, Object?> toJson() => const {'kind': 'none'};
}

/// Signed in through Anthropic's OAuth login. [usableLogin]: a login is there
/// and has not lapsed — what a launch decides inherited credentials on.
final class AnthropicSignIn extends AgentSignIn {
  const AnthropicSignIn(this.snapshot, {this.usableLogin = false});

  final ClaudeAuthSnapshot snapshot;
  final bool usableLogin;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'anthropicOAuth',
    'environmentId': snapshot.environmentId,
    if (snapshot.email != null) 'email': snapshot.email,
    if (snapshot.keychainRefusal != null)
      'keychainRefusal': snapshot.keychainRefusal,
    if (snapshot.readFailure != null) 'readFailure': snapshot.readFailure,
    if (snapshot.organizationName != null)
      'organizationName': snapshot.organizationName,
    if (snapshot.organizationUuid != null)
      'organizationUuid': snapshot.organizationUuid,
    if (snapshot.subscriptionType != null)
      'subscriptionType': snapshot.subscriptionType,
    if (snapshot.rateLimitTier != null) 'rateLimitTier': snapshot.rateLimitTier,
    if (snapshot.accessTokenExpiresAt != null)
      'accessTokenExpiresAt': _time(snapshot.accessTokenExpiresAt!),
    'usableLogin': usableLogin,
  };

  static AnthropicSignIn fromJson(Map<String, Object?> json) => AnthropicSignIn(
    ClaudeAuthSnapshot(
      environmentId: _string(json, 'environmentId'),
      email: _optional(json, 'email'),
      keychainRefusal: _optional(json, 'keychainRefusal'),
      readFailure: _optional(json, 'readFailure'),
      organizationName: _optional(json, 'organizationName'),
      organizationUuid: _optional(json, 'organizationUuid'),
      subscriptionType: _optional(json, 'subscriptionType'),
      rateLimitTier: _optional(json, 'rateLimitTier'),
      accessTokenExpiresAt: _optionalDate(json['accessTokenExpiresAt']),
    ),
    usableLogin: json['usableLogin'] == true,
  );
}

/// Signed in through an OpenAI `auth.json`.
final class OpenAiSignIn extends AgentSignIn {
  const OpenAiSignIn(this.snapshot);

  final CodexAuthSnapshot snapshot;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'openAiAuthFile',
    'environmentId': snapshot.environmentId,
    if (snapshot.readFailure != null) 'readFailure': snapshot.readFailure,
    if (snapshot.accountId != null) 'accountId': snapshot.accountId,
    if (snapshot.email != null) 'email': snapshot.email,
    if (snapshot.planType != null) 'planType': snapshot.planType,
    if (snapshot.accessTokenExpiresAt != null)
      'accessTokenExpiresAt': _time(snapshot.accessTokenExpiresAt!),
  };

  static OpenAiSignIn fromJson(Map<String, Object?> json) => OpenAiSignIn(
    CodexAuthSnapshot(
      environmentId: _string(json, 'environmentId'),
      readFailure: _optional(json, 'readFailure'),
      accountId: _optional(json, 'accountId'),
      email: _optional(json, 'email'),
      planType: _optional(json, 'planType'),
      accessTokenExpiresAt: _optionalDate(json['accessTokenExpiresAt']),
    ),
  );
}

/// What `acpAgents.install` answers: where the executable landed, spelled
/// for the machine it is on, and what looking for the agent again found when
/// the request named one.
final class AcpAgentInstalled {
  const AcpAgentInstalled({required this.executablePath, this.report});

  final String executablePath;
  final AgentDiscoveryReport? report;

  Map<String, Object?> toJson() => {
    'executablePath': executablePath,
    if (report case final report?) 'report': discoveryReportToJson(report),
  };

  factory AcpAgentInstalled.fromJson(Map<String, Object?> json) =>
      AcpAgentInstalled(
        executablePath: _string(json, 'executablePath'),
        report: json['report'] == null
            ? null
            : discoveryReportFromJson(_object(json['report'])),
      );
}

// Detection reports.

Map<String, Object?> discoveryReportToJson(AgentDiscoveryReport report) => {
  'environments': [
    for (final environment in report.environments)
      environmentScanToJson(environment),
  ],
};

AgentDiscoveryReport discoveryReportFromJson(Map<String, Object?> json) =>
    AgentDiscoveryReport([
      for (final item in _list(json['environments']))
        environmentScanFromJson(_object(item)),
    ]);

Map<String, Object?> environmentScanToJson(EnvironmentScanReport report) => {
  'environmentId': report.environmentId,
  'environmentName': report.environmentName,
  'reachable': report.reachable,
  if (report.error != null) 'error': report.error,
  'found': _installations(report.found),
  'missing': report.missing,
  'added': _installations(report.added),
  'removed': _installations(report.removed),
  'retained': _installations(report.retained),
  'updated': [
    for (final change in report.updated)
      {
        'displayName': change.displayName,
        if (change.from != null) 'from': change.from,
        if (change.to != null) 'to': change.to,
      },
  ],
  'movedPaths': [
    for (final change in report.movedPaths)
      {'displayName': change.displayName, 'from': change.from, 'to': change.to},
  ],
  'unreachablePaths': _installations(report.unreachablePaths),
  'pinnedPaths': _installations(report.pinnedPaths),
};

EnvironmentScanReport environmentScanFromJson(Map<String, Object?> json) =>
    EnvironmentScanReport(
      environmentId: _string(json, 'environmentId'),
      environmentName: _string(json, 'environmentName'),
      reachable: json['reachable'] == true,
      error: _optional(json, 'error'),
      found: _installationsFrom(json['found']),
      missing: [for (final name in _list(json['missing'])) name as String],
      added: _installationsFrom(json['added']),
      removed: _installationsFrom(json['removed']),
      retained: _installationsFrom(json['retained']),
      updated: [
        for (final item in _list(json['updated'])) versionChangeFrom(item),
      ],
      movedPaths: [
        for (final item in _list(json['movedPaths']))
          () {
            final change = _object(item);
            return AgentPathChange(
              displayName: _string(change, 'displayName'),
              from: _string(change, 'from'),
              to: _string(change, 'to'),
            );
          }(),
      ],
      unreachablePaths: _installationsFrom(json['unreachablePaths']),
      pinnedPaths: _installationsFrom(json['pinnedPaths']),
    );

Map<String, Object?> versionChangeToJson(AgentVersionChange change) => {
  'displayName': change.displayName,
  if (change.from != null) 'from': change.from,
  if (change.to != null) 'to': change.to,
};

AgentVersionChange versionChangeFrom(Object? item) {
  final change = _object(item);
  return AgentVersionChange(
    displayName: _string(change, 'displayName'),
    from: _optional(change, 'from'),
    to: _optional(change, 'to'),
  );
}

Map<String, Object?> pathRepairToJson(AgentPathRepairReport report) => {
  if (report.checkedAt != null) 'checkedAt': _time(report.checkedAt!),
  'broken': [for (final r in report.broken) _readingToJson(r)],
  'repaired': [for (final r in report.repaired) _readingToJson(r)],
  'unresolved': [for (final r in report.unresolved) _readingToJson(r)],
  if (report.scan != null) 'scan': discoveryReportToJson(report.scan!),
};

AgentPathRepairReport pathRepairFromJson(Map<String, Object?> json) {
  final checkedAt = _optionalDate(json['checkedAt']);
  if (checkedAt == null) return const AgentPathRepairReport.unchecked();
  return AgentPathRepairReport(
    checkedAt: checkedAt,
    broken: [for (final r in _list(json['broken'])) _readingFrom(r)],
    repaired: [for (final r in _list(json['repaired'])) _readingFrom(r)],
    unresolved: [for (final r in _list(json['unresolved'])) _readingFrom(r)],
    scan: json['scan'] == null
        ? null
        : discoveryReportFromJson(_object(json['scan'])),
  );
}

Map<String, Object?> _readingToJson(AgentPathReading reading) => {
  'installation': installationToJson(reading.installation),
  'displayName': reading.displayName,
  'path': reading.reading.path,
  'reachability': reading.reading.reachability.name,
  if (reading.reading.resolved != null) 'resolved': reading.reading.resolved,
};

AgentPathReading _readingFrom(Object? item) {
  final json = _object(item);
  return AgentPathReading(
    installation: installationFromJson(_object(json['installation'])),
    displayName: _string(json, 'displayName'),
    reading: ExecutableReading(
      path: _string(json, 'path'),
      reachability: _enum(ExecutableReachability.values, json['reachability']),
      resolved: _optional(json, 'resolved'),
    ),
  );
}

List<Object?> _installations(List<AgentInstallation> rows) => [
  for (final row in rows) installationToJson(row),
];

List<AgentInstallation> _installationsFrom(Object? json) => [
  for (final item in _list(json)) installationFromJson(_object(item)),
];

// The CLI import.

Map<String, Object?> detectedSessionToJson(DetectedSession session) => {
  'cli': session.cli,
  'sessionId': session.sessionId,
  'cwd': environmentPathToJson(session.cwd),
  'filePath': session.filePath,
  'storeHome': session.storeHome,
  if (session.title != null) 'title': session.title,
  'preview': session.preview,
  if (session.startedAt != null) 'startedAt': _time(session.startedAt!),
  if (session.modifiedAt != null) 'modifiedAt': _time(session.modifiedAt!),
  if (session.entrypoint != null) 'entrypoint': session.entrypoint,
};

DetectedSession detectedSessionFromJson(Map<String, Object?> json) =>
    DetectedSession(
      cli: _string(json, 'cli'),
      sessionId: _string(json, 'sessionId'),
      cwd: environmentPathFromJson(json['cwd']),
      filePath: _string(json, 'filePath'),
      storeHome: _string(json, 'storeHome'),
      title: _optional(json, 'title'),
      preview: _optional(json, 'preview') ?? '',
      startedAt: _optionalDate(json['startedAt']),
      modifiedAt: _optionalDate(json['modifiedAt']),
      entrypoint: _optional(json, 'entrypoint'),
    );

Map<String, Object?> detectedProjectToJson(DetectedProject project) => {
  'canonicalKey': project.canonicalKey,
  'displayPath': project.displayPath,
  'sessions': [for (final s in project.sessions) detectedSessionToJson(s)],
  'subagentSessions': [
    for (final s in project.subagentSessions) detectedSessionToJson(s),
  ],
};

DetectedProject detectedProjectFromJson(Map<String, Object?> json) =>
    DetectedProject(
      canonicalKey: _string(json, 'canonicalKey'),
      displayPath: _string(json, 'displayPath'),
      sessions: [
        for (final s in _list(json['sessions']))
          detectedSessionFromJson(_object(s)),
      ],
      subagentSessions: [
        for (final s in _list(json['subagentSessions']))
          detectedSessionFromJson(_object(s)),
      ],
    );

/// Counts of what an import added (duplicates are not counted).
final class ImportSummary {
  const ImportSummary({
    this.projects = 0,
    this.repositories = 0,
    this.sessions = 0,
  });

  final int projects;
  final int repositories;
  final int sessions;

  ImportSummary operator +(ImportSummary other) => ImportSummary(
    projects: projects + other.projects,
    repositories: repositories + other.repositories,
    sessions: sessions + other.sessions,
  );

  bool get isEmpty => projects == 0 && repositories == 0 && sessions == 0;

  Map<String, Object?> toJson() => {
    'projects': projects,
    'repositories': repositories,
    'sessions': sessions,
  };

  static ImportSummary fromJson(Map<String, Object?> json) => ImportSummary(
    projects: _int(json, 'projects'),
    repositories: _int(json, 'repositories'),
    sessions: _int(json, 'sessions'),
  );
}

// Helpers.

String _time(DateTime value) => value.toUtc().toIso8601String();

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('"$key" must be a string');
}

String? _optional(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null || value is String) return value as String?;
  throw FormatException('"$key" must be a string or absent');
}

int _int(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) return value;
  throw FormatException('"$key" must be a whole number');
}

DateTime _date(Object? value) {
  final parsed = value is String ? DateTime.tryParse(value) : null;
  if (parsed == null) throw const FormatException('not a time');
  return parsed.toUtc();
}

DateTime? _optionalDate(Object? value) => value == null ? null : _date(value);

T _enum<T extends Enum>(List<T> values, Object? name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException('not one of ${values.map((v) => v.name)}: $name');
}

Map<String, Object?> _object(Object? json) {
  if (json is Map) return json.cast<String, Object?>();
  throw const FormatException('expected an object');
}

List<Object?> _list(Object? json) {
  if (json is List) return json;
  throw const FormatException('expected a list');
}
