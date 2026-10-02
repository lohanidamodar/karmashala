import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/read.dart' show DetectedProject;
import 'package:agent_cli/usage.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/karmashala_environments.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';
import '../../../core/data/keyed_replica.dart';

/// The agent installations as the server keeps them: read at once from this
/// app's copy, in the table's order. The server finds them ([AgentWorkData])
/// and writes them; this app only sets a path a person chose.
class AgentInstallationsData {
  AgentInstallationsData(this._client);

  final DataClient _client;
  List<AgentInstallation>? _sorted;
  var _sortedAt = -1;

  Stream<void> get changes => _client.installations.changes;

  bool get isPrimed => _client.installations.isPrimed;

  AgentInstallation? getById(String id) => _client.installations[id];

  /// Every installation, oldest first (`compareInstallations`).
  List<AgentInstallation> getAll() {
    final replica = _client.installations;
    if (_sortedAt != replica.version) {
      _sorted = List.unmodifiable(
        <AgentInstallation>[...replica.values]..sort(compareInstallations),
      );
      _sortedAt = replica.version;
    }
    return _sorted!;
  }

  List<AgentInstallation> getByEnvironment(String environmentId) => [
    for (final row in getAll())
      if (row.environmentId == environmentId) row,
  ];

  /// The row at `(agentId, environmentId, path)` — the table's identity.
  AgentInstallation? getByIdentity(
    String agentId,
    String environmentId,
    String path,
  ) {
    for (final row in getAll()) {
      if (row.agentId == agentId &&
          row.environmentId == environmentId &&
          row.executable.path == path) {
        return row;
      }
    }
    return null;
  }

  /// Points installation [id] at [path], as a person chose it. Throws
  /// [DataRefused] when another row of that agent there holds [path].
  Future<AgentInstallation> setPath(String id, String path) => _client.write(
    InstallationSetPath(id: id, path: path),
    domain: DataDomain.agents,
  );
}

/// The saved Claude accounts, **without their credentials**: the copy and
/// every change carry none. The server captures and switches them
/// ([AgentWorkData]); a token never reaches this app.
class ClaudeAccountsData {
  ClaudeAccountsData(this._client);

  final DataClient _client;

  Stream<void> get changes => _client.claudeAccounts.changes;

  List<ClaudeAccount> getAll() =>
      [..._client.claudeAccounts.values]..sort(compareClaudeAccounts);

  Future<void> delete(String id) =>
      _client.write(ClaudeAccountDelete(id), domain: DataDomain.agents);
}

/// The saved Codex accounts, **without their credentials** — as
/// [ClaudeAccountsData].
class CodexAccountsData {
  CodexAccountsData(this._client);

  final DataClient _client;

  Stream<void> get changes => _client.codexAccounts.changes;

  List<CodexAccount> getAll() =>
      [..._client.codexAccounts.values]..sort(compareCodexAccounts);

  Future<void> delete(String id) =>
      _client.write(CodexAccountDelete(id), domain: DataDomain.agents);
}

/// The usage history at the server, which records every reading it takes
/// (keeping what is worth a row, `usageSampleWorthKeeping`, and pruning); a
/// chart asks for an account's history. Nothing of it is copied here.
class UsageHistoryData {
  UsageHistoryData(this._client);

  final DataClient _client;

  /// The account whose history gained rows, here or at another client.
  Stream<String> get recorded => _client.usageRecorded;

  /// [accountKey]'s history since [since], oldest first.
  Future<List<UsageSample>> since(String accountKey, DateTime since) async =>
      (await _client.send(UsageHistory(accountKey, since))).value;
}

/// The work the server does for its agents, asked for: usage read now,
/// who is signed in and switching who is, finding the agents, and the CLI
/// import. Each is answered when the server's work is done; the rows it
/// wrote reach this app's copies as changes first.
class AgentWorkData {
  AgentWorkData(this._client);

  final DataClient _client;

  Future<R> _ask<R>(AgentWorkRequest<R> request) async =>
      (await _client.send(request)).value;

  /// Every account's usage as the server last read it, by account key.
  KeyedReplica<AccountUsageState> get usage => _client.usageStates;

  /// Asks the server to read [accountKey] (every account when null) now —
  /// through its throttle — and answers the accounts as they then stand.
  Future<List<AccountUsageState>> refreshUsage([String? accountKey]) =>
      _ask(UsageRefresh(accountKey: accountKey));

  /// Who is signed in to installation [installationId] now.
  Future<AgentSignIn> signIn(String installationId) =>
      _ask(AccountsCurrent(installationId));

  /// Captures the account signed in to [installationId]; answers its id.
  Future<String> capture(String installationId) =>
      _ask(AccountsCapture(installationId));

  /// Signs [installationId] in as saved account [accountId].
  Future<void> switchTo(String installationId, String accountId) => _ask(
    AccountsSwitch(installationId: installationId, accountId: accountId),
  );

  /// Probes every environment (or [environmentId] alone, add-only).
  Future<AgentDiscoveryReport> detect({String? environmentId}) =>
      _ask(AgentsDetect(environmentId: environmentId));

  /// Checks the recorded executables and repairs rotted paths.
  Future<AgentPathRepairReport> repair({bool full = false}) =>
      _ask(AgentsRepair(full: full));

  /// Downloads a registry entry's prebuilt archive into [environmentId]'s
  /// managed folder and unpacks it; with [agentId], looks for that agent
  /// there again. Answers where the executable landed.
  Future<AcpAgentInstalled> installAcpBinary({
    required String environmentId,
    required String registryId,
    required String version,
    required String archive,
    required String command,
    List<String> args = const [],
    String? sha256,
    String? agentId,
  }) => _ask(
    AcpAgentInstall(
      environmentId: environmentId,
      registryId: registryId,
      version: version,
      archive: archive,
      command: command,
      args: args,
      sha256: sha256,
      agentId: agentId,
    ),
  );

  /// Each step of an install under way, as the server tells it.
  Stream<AcpInstallProgress> get installProgress => _client.acpInstallProgress;

  /// The conversations the agents' own stores hold, merged into projects.
  Future<List<DetectedProject>> scanImports() => _ask(const ImportsScan());

  /// Imports [projects] as the workspace's projects and history.
  Future<ImportSummary> addImports(List<DetectedProject> projects) =>
      _ask(ImportsAdd(projects));

  /// Imports as history what the stores hold for checkouts [repositoryIds].
  Future<ImportSummary> importForRepositories(List<String> repositoryIds) =>
      _ask(ImportsForRepositories(repositoryIds));
}

final agentWorkProvider = Provider<AgentWorkData>(
  (ref) => AgentWorkData(ref.watch(dataClientProvider)),
);

final agentInstallationsDataProvider = Provider<AgentInstallationsData>(
  (ref) => AgentInstallationsData(ref.watch(dataClientProvider)),
);

final claudeAccountsDataProvider = Provider<ClaudeAccountsData>(
  (ref) => ClaudeAccountsData(ref.watch(dataClientProvider)),
);

final codexAccountsDataProvider = Provider<CodexAccountsData>(
  (ref) => CodexAccountsData(ref.watch(dataClientProvider)),
);

final usageHistoryDataProvider = Provider<UsageHistoryData>(
  (ref) => UsageHistoryData(ref.watch(dataClientProvider)),
);
