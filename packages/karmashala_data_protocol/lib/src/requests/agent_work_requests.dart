part of '../data_request.dart';

// The work the server does for the agents on its machine (slice 2a): their
// usage, who is signed in to them, finding them, and importing their CLI
// history. Every one reads a disk, a keychain or a vendor's endpoint, so
// every one is answered when its work is done (`DataSession.handleLater`),
// and what it writes is told to every client as the rows it wrote.

DataRequest<Object?>? _agentWorkRequestFromJson(
  String kind,
  _Arguments args,
) => switch (kind) {
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
  AgentsRepair.name => AgentsRepair(full: args.boolean('full', orElse: false)),
  AgentsRefreshVersions.name => const AgentsRefreshVersions(),
  AgentsDiscoverUnprobed.name => const AgentsDiscoverUnprobed(),
  AcpAgentInstall.name => AcpAgentInstall(
    environmentId: args.string('environmentId'),
    registryId: args.string('registryId'),
    version: args.string('version'),
    archive: args.string('archive'),
    command: args.string('command'),
    args: args.strings('args', orEmpty: true),
    sha256: args.optionalString('sha256'),
    agentId: args.optionalString('agentId'),
  ),
  ImportsScan.name => const ImportsScan(),
  ImportsAdd.name => ImportsAdd(
    args.objects('projects', detectedProjectFromJson),
  ),
  ImportsForRepositories.name => ImportsForRepositories(
    args.strings('repositoryIds'),
  ),
  AcpAuthMethodsRead.name => AcpAuthMethodsRead(args.string('installationId')),
  AcpAuthStateRead.name => AcpAuthStateRead(args.string('installationId')),
  AcpAuthenticate.name => AcpAuthenticate(
    installationId: args.string('installationId'),
    methodId: args.string('methodId'),
  ),
  AcpAuthTerminalLogin.name => AcpAuthTerminalLogin(
    installationId: args.string('installationId'),
    methodId: args.string('methodId'),
  ),
  AcpAuthClear.name => AcpAuthClear(
    args.string('installationId'),
    logout: args.boolean('logout', orElse: false),
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

/// Downloads the archive the public ACP registry ships for one agent and one
/// platform into [environmentId]'s managed folder
/// (`~/karmashala/acp/<registryId>/<version>/`), checks it against [sha256]
/// when the registry gives one, unpacks it and marks [command] executable.
/// With [agentId], the server then looks for that agent there again so the
/// installation is recorded. Told as it goes ([AcpInstallProgress]);
/// answered with where the executable landed. Refused in the shell's words
/// when a step fails.
final class AcpAgentInstall extends AgentWorkRequest<AcpAgentInstalled> {
  const AcpAgentInstall({
    required this.environmentId,
    required this.registryId,
    required this.version,
    required this.archive,
    required this.command,
    this.args = const [],
    this.sha256,
    this.agentId,
  });

  static const String name = 'acpAgents.install';

  final String environmentId;
  final String registryId;
  final String version;

  /// The archive's URL, as the registry's binary distribution gives it.
  final String archive;

  /// The command inside the archive (`./agy_acp_server.par`), and the argv
  /// the registry says to start it with.
  final String command;
  final List<String> args;
  final String? sha256;

  /// The shipped agent this installs, when it is one.
  final String? agentId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'environmentId': environmentId,
    'registryId': registryId,
    'version': version,
    'archive': archive,
    'command': command,
    'args': args,
    'sha256': ?sha256,
    'agentId': ?agentId,
  };

  @override
  Object? resultToJson(AcpAgentInstalled result) => result.toJson();

  @override
  AcpAgentInstalled resultFromJson(Object? json) =>
      _decode(kind, () => AcpAgentInstalled.fromJson(_object(json, kind)));
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

// Logging in to an ACP agent. ACP v1 names methods, not accounts, so nothing
// here says who is logged in.

/// The auth methods installation [installationId] advertises on
/// `initialize`, read over a connection the server opens and ends.
final class AcpAuthMethodsRead extends AgentWorkRequest<AcpAuthMethods> {
  const AcpAuthMethodsRead(this.installationId);

  static const String name = 'acpAuth.methods';

  final String installationId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'installationId': installationId};

  @override
  Object? resultToJson(AcpAuthMethods result) => result.toJson();

  @override
  AcpAuthMethods resultFromJson(Object? json) =>
      _decode(kind, () => AcpAuthMethods.fromJson(_object(json, kind)));
}

/// The method remembered for installation [installationId]; null when none
/// was chosen.
final class AcpAuthStateRead extends AgentWorkRequest<AcpAuthState?> {
  const AcpAuthStateRead(this.installationId);

  static const String name = 'acpAuth.state';

  final String installationId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'installationId': installationId};

  @override
  Object? resultToJson(AcpAuthState? result) => result?.toJson();

  @override
  AcpAuthState? resultFromJson(Object? json) => json == null
      ? null
      : _decode(kind, () => AcpAuthState.fromJson(_object(json, kind)));
}

/// Asks installation [installationId] to `authenticate` with [methodId] over
/// a short-lived connection, and remembers the method once it succeeded.
/// Refused `failed` in the agent's own words when it did not.
final class AcpAuthenticate extends AgentWorkRequest<AcpAuthState> {
  const AcpAuthenticate({required this.installationId, required this.methodId});

  static const String name = 'acpAuth.authenticate';

  final String installationId;
  final String methodId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'installationId': installationId,
    'methodId': methodId,
  };

  @override
  Object? resultToJson(AcpAuthState result) => result.toJson();

  @override
  AcpAuthState resultFromJson(Object? json) =>
      _decode(kind, () => AcpAuthState.fromJson(_object(json, kind)));
}

/// Opens a terminal on installation [installationId]'s machine running the
/// login terminal method [methodId] names, shown as a tab in the window a
/// person last used, and remembers the method unconfirmed.
final class AcpAuthTerminalLogin extends AgentWorkRequest<AcpAuthState> {
  const AcpAuthTerminalLogin({
    required this.installationId,
    required this.methodId,
  });

  static const String name = 'acpAuth.terminalLogin';

  final String installationId;
  final String methodId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'installationId': installationId,
    'methodId': methodId,
  };

  @override
  Object? resultToJson(AcpAuthState result) => result.toJson();

  @override
  AcpAuthState resultFromJson(Object? json) =>
      _decode(kind, () => AcpAuthState.fromJson(_object(json, kind)));
}

/// Forgets the method remembered for installation [installationId]; with
/// [logout], an agent that answers `logout` is asked to end its login too.
final class AcpAuthClear extends AgentWorkRequest<DataAck> {
  const AcpAuthClear(this.installationId, {this.logout = false});

  static const String name = 'acpAuth.clear';

  final String installationId;
  final bool logout;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'installationId': installationId,
    'logout': logout,
  };

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}
