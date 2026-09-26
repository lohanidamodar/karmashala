part of '../data_request.dart';

// The work the server does for the agents on its machine (slice 2a): their
// usage, who is signed in to them, finding them, and importing their CLI
// history. Every one reads a disk, a keychain or a vendor's endpoint, so
// every one is answered when its work is done (`DataSession.handleLater`),
// and what it writes is told to every client as the rows it wrote.

DataRequest<Object?>? _agentWorkRequestFromJson(String kind, _Arguments args) =>
    switch (kind) {
      UsageCurrent.name => const UsageCurrent(),
      UsageRefresh.name => UsageRefresh(
        accountKey: args.optionalString('accountKey'),
      ),
      AccountsCurrent.name => AccountsCurrent(args.string('installationId')),
      AccountsCapture.name => AccountsCapture(args.string('installationId')),
      AccountsSwitch.name => AccountsSwitch(
        installationId: args.string('installationId'),
        accountId: args.string('accountId'),
      ),
      AgentsDetect.name => AgentsDetect(
        environmentId: args.optionalString('environmentId'),
      ),
      AgentsRepair.name => AgentsRepair(
        full: args.boolean('full', orElse: false),
      ),
      AgentsRefreshVersions.name => const AgentsRefreshVersions(),
      AgentsDiscoverUnprobed.name => const AgentsDiscoverUnprobed(),
      ImportsScan.name => const ImportsScan(),
      ImportsAdd.name => ImportsAdd(
        args.objects('projects', detectedProjectFromJson),
      ),
      ImportsForRepositories.name => ImportsForRepositories(
        args.strings('repositoryIds'),
      ),
      _ => null,
    };

/// Work the server does on its own machine for its agents; answered when
/// done.
sealed class AgentWorkRequest<R> extends DataRequest<R> {
  const AgentWorkRequest();
}

// Usage.

/// Every account's usage as the server last read it. The server reads each
/// on its own schedule (never under the account's floor), so this costs no
/// request to any vendor.
final class UsageCurrent extends AgentWorkRequest<List<AccountUsageState>> {
  const UsageCurrent();

  static const String name = 'usage.current';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(List<AccountUsageState> result) => [
    for (final state in result) state.toJson(),
  ];

  @override
  List<AccountUsageState> resultFromJson(Object? json) => _decode(kind, () {
    return [
      for (final item in _objects(json, kind)) AccountUsageState.fromJson(item),
    ];
  });
}

/// Asks the server to read [accountKey]'s usage now (every account's when
/// null) — through its throttle, so inside an account's floor the last
/// reading answers and a rate limit in force is sat out, not pushed on.
/// Answered with the accounts as they then stand.
final class UsageRefresh extends AgentWorkRequest<List<AccountUsageState>> {
  const UsageRefresh({this.accountKey});

  static const String name = 'usage.refresh';

  final String? accountKey;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'accountKey': ?accountKey};

  @override
  Object? resultToJson(List<AccountUsageState> result) => [
    for (final state in result) state.toJson(),
  ];

  @override
  List<AccountUsageState> resultFromJson(Object? json) => _decode(kind, () {
    return [
      for (final item in _objects(json, kind)) AccountUsageState.fromJson(item),
    ];
  });
}

// Accounts. No token crosses: the server reads, captures and writes them.

/// Who is signed in to installation [installationId] now, read from its own
/// files (or the login Keychain) by the server — identity and expiry only.
final class AccountsCurrent extends AgentWorkRequest<AgentSignIn> {
  const AccountsCurrent(this.installationId);

  static const String name = 'accounts.current';

  final String installationId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'installationId': installationId};

  @override
  Object? resultToJson(AgentSignIn result) => result.toJson();

  @override
  AgentSignIn resultFromJson(Object? json) =>
      _decode(kind, () => AgentSignIn.fromJson(_object(json, kind)));
}

/// Captures the account signed in to installation [installationId] and saves
/// it — the same account again keeps its id. Answers the saved account's id;
/// the row (without its credentials) is told as a change.
final class AccountsCapture extends AgentWorkRequest<String> {
  const AccountsCapture(this.installationId);

  static const String name = 'accounts.capture';

  final String installationId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'installationId': installationId};

  @override
  Object? resultToJson(String result) => result;

  @override
  String resultFromJson(Object? json) =>
      json is String ? json : _badAnswer(kind);
}

/// Signs installation [installationId] in as saved account [accountId]: the
/// account signed in now is captured first, so it can be switched back to.
final class AccountsSwitch extends AgentWorkRequest<DataAck> {
  const AccountsSwitch({required this.installationId, required this.accountId});

  static const String name = 'accounts.switch';

  final String installationId;
  final String accountId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'installationId': installationId,
    'accountId': accountId,
  };

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

// Detection.

/// Probes every environment (or only [environmentId]) for the agent CLIs the
/// registry knows and records what answered by the one rule
/// (`planReconcile`). A sweep of every environment judges what it no longer
/// found; one environment's scan only adds. Answers the report a person
/// reads: what was found, moved, kept, and what could not be reached.
final class AgentsDetect extends AgentWorkRequest<AgentDiscoveryReport> {
  const AgentsDetect({this.environmentId});

  static const String name = 'agents.detect';

  final String? environmentId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'environmentId': ?environmentId};

  @override
  Object? resultToJson(AgentDiscoveryReport result) =>
      discoveryReportToJson(result);

  @override
  AgentDiscoveryReport resultFromJson(Object? json) =>
      _decode(kind, () => discoveryReportFromJson(_object(json, kind)));
}

/// Checks every recorded executable the server can judge and repairs the
/// rows whose path rotted; [full] re-probes everything on the way.
final class AgentsRepair extends AgentWorkRequest<AgentPathRepairReport> {
  const AgentsRepair({this.full = false});

  static const String name = 'agents.repair';

  final bool full;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'full': full};

  @override
  Object? resultToJson(AgentPathRepairReport result) =>
      pathRepairToJson(result);

  @override
  AgentPathRepairReport resultFromJson(Object? json) =>
      _decode(kind, () => pathRepairFromJson(_object(json, kind)));
}

/// Re-reads the versions whose reading aged out; answers what changed.
final class AgentsRefreshVersions
    extends AgentWorkRequest<List<AgentVersionChange>> {
  const AgentsRefreshVersions();

  static const String name = 'agents.refreshVersions';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(List<AgentVersionChange> result) => [
    for (final change in result) versionChangeToJson(change),
  ];

  @override
  List<AgentVersionChange> resultFromJson(Object? json) => _decode(kind, () {
    return [for (final item in _objects(json, kind)) versionChangeFrom(item)];
  });
}

/// Probes only the (agent, environment) pairs nobody has searched yet — what
/// makes an agent a newer build knows visible. Answers what it found.
final class AgentsDiscoverUnprobed
    extends AgentWorkRequest<List<AgentInstallation>> {
  const AgentsDiscoverUnprobed();

  static const String name = 'agents.discoverUnprobed';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(List<AgentInstallation> result) => [
    for (final row in result) installationToJson(row),
  ];

  @override
  List<AgentInstallation> resultFromJson(Object? json) => _decode(kind, () {
    return [
      for (final item in _objects(json, kind)) installationFromJson(item),
    ];
  });
}

// The CLI import.

/// Reads every agent's own store on the server's machine and answers the
/// conversations found, merged into projects by folder. Imports nothing.
final class ImportsScan extends AgentWorkRequest<List<DetectedProject>> {
  const ImportsScan();

  static const String name = 'imports.scan';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(List<DetectedProject> result) => [
    for (final project in result) detectedProjectToJson(project),
  ];

  @override
  List<DetectedProject> resultFromJson(Object? json) => _decode(kind, () {
    return [
      for (final item in _objects(json, kind)) detectedProjectFromJson(item),
    ];
  });
}

/// Imports [projects] (from [ImportsScan]): a project and a checkout per
/// folder, found or created, and each conversation as imported history
/// unless it is recorded already. Answers what was added.
final class ImportsAdd extends AgentWorkRequest<ImportSummary> {
  const ImportsAdd(this.projects);

  static const String name = 'imports.add';

  final List<DetectedProject> projects;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'projects': [for (final p in projects) detectedProjectToJson(p)],
  };

  @override
  Object? resultToJson(ImportSummary result) => result.toJson();

  @override
  ImportSummary resultFromJson(Object? json) =>
      _decode(kind, () => ImportSummary.fromJson(_object(json, kind)));
}

/// Imports, as history, every conversation the agents' stores hold for
/// checkouts [repositoryIds] — by exact folder; a conversation a session row
/// already runs is not history. Answers what was added.
final class ImportsForRepositories extends AgentWorkRequest<ImportSummary> {
  const ImportsForRepositories(this.repositoryIds);

  static const String name = 'imports.forRepositories';

  final List<String> repositoryIds;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'repositoryIds': repositoryIds};

  @override
  Object? resultToJson(ImportSummary result) => result.toJson();

  @override
  ImportSummary resultFromJson(Object? json) =>
      _decode(kind, () => ImportSummary.fromJson(_object(json, kind)));
}
