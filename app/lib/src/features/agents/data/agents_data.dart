import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/karmashala_environments.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// The agent installations as the server keeps them: read at once from this
/// app's copy, in the table's order; written through the server, which
/// applies the one reconciliation of a probe with the rows (`planReconcile`
/// — a pinned path stands, a moved CLI keeps its id, a row something points
/// at is kept). This app still probes the environments only it can reach
/// (WSL, SSH, this machine's junctions) and reports what it found.
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

  /// Reconciles what a probe of [environmentId] [found] with its rows at the
  /// server. Its answer is in the copy when this completes. Throws
  /// [DataRefused].
  Future<InstallationsReconciled> reconcile({
    required String environmentId,
    required DateTime readAt,
    List<AgentInstallation> found = const [],
    Set<String> probed = const {},
    Map<String, ExecutableReachability> readings = const {},
  }) => _client.write(
    InstallationsReconcile(
      environmentId: environmentId,
      readAt: readAt,
      found: found,
      probed: probed,
      readings: readings,
    ),
    domain: DataDomain.agents,
  );

  /// Records what installation [id]'s CLI answered, read at [readAt].
  Future<AgentInstallation> recordVersion(
    String id,
    String version, {
    required DateTime readAt,
  }) => _client.write(
    InstallationVersion(id: id, version: version, readAt: readAt),
    domain: DataDomain.agents,
  );

  /// Points installation [id] at [path], as a person chose it. Throws
  /// [DataRefused] when another row of that agent there holds [path].
  Future<AgentInstallation> setPath(String id, String path) => _client.write(
    InstallationSetPath(id: id, path: path),
    domain: DataDomain.agents,
  );
}

/// The saved Claude accounts, **without their credentials**: the copy and
/// every change carry none. [credentials] asks the server for one account's
/// token bundle, right before an installation is switched to it.
class ClaudeAccountsData {
  ClaudeAccountsData(this._client);

  final DataClient _client;

  Stream<void> get changes => _client.claudeAccounts.changes;

  List<ClaudeAccount> getAll() =>
      [..._client.claudeAccounts.values]..sort(compareClaudeAccounts);

  /// Saves a captured account (the same email and organization keeps its
  /// id); answers it without its credentials.
  Future<ClaudeAccount> save(ClaudeAccount account) =>
      _client.write(ClaudeAccountSave(account), domain: DataDomain.agents);

  Future<ClaudeAccount> credentials(String id) async =>
      (await _client.send(ClaudeAccountCredentials(id))).value;

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

  Future<CodexAccount> save(CodexAccount account) =>
      _client.write(CodexAccountSave(account), domain: DataDomain.agents);

  Future<CodexAccount> credentials(String id) async =>
      (await _client.send(CodexAccountCredentials(id))).value;

  Future<void> delete(String id) =>
      _client.write(CodexAccountDelete(id), domain: DataDomain.agents);
}

/// The usage history at the server: a reading is recorded there (it keeps
/// what is worth a row, `usageSampleWorthKeeping`, and prunes), and a chart
/// asks for an account's history. Nothing of it is copied here.
class UsageHistoryData {
  UsageHistoryData(this._client);

  final DataClient _client;

  /// The account whose history gained rows, here or at another client.
  Stream<String> get recorded => _client.usageRecorded;

  /// Records [usage] for [accountKey]; answers how many rows were written.
  Future<int> record(String accountKey, AgentUsage usage) {
    final samples = usageSamplesOf(accountKey, usage);
    if (samples.isEmpty) return Future.value(0);
    return _client.write(UsageRecord(samples), domain: DataDomain.agents);
  }

  /// [accountKey]'s history since [since], oldest first.
  Future<List<UsageSample>> since(String accountKey, DateTime since) async =>
      (await _client.send(UsageHistory(accountKey, since))).value;
}

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
