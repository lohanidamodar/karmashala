part of '../data_request.dart';

// Where agents run: environments, saved SSH hosts, trusted host keys.

/// Every environment, saved SSH host (with its key's location) and trusted
/// host key.
final class EnvironmentsList extends DataRequest<EnvironmentsSnapshot> {
  const EnvironmentsList();

  static const String name = 'environments.list';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(EnvironmentsSnapshot result) => result.toJson();

  @override
  EnvironmentsSnapshot resultFromJson(Object? json) =>
      _decode(kind, () => EnvironmentsSnapshot.fromJson(_object(json, kind)));
}

/// Records an environment discovery found — this machine, or a WSL
/// distribution — created or renamed. Refused for one out of shape
/// (`environmentProblem`), and for an SSH environment, which is its host's.
final class EnvironmentPut extends DataRequest<ExecutionEnvironment> {
  const EnvironmentPut(this.environment);

  static const String name = 'environments.put';

  final ExecutionEnvironment environment;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'environment': environmentToJson(environment),
  };

  @override
  Object? resultToJson(ExecutionEnvironment result) =>
      environmentToJson(result);

  @override
  ExecutionEnvironment resultFromJson(Object? json) =>
      _decode(kind, () => environmentFromJson(_object(json, kind)));
}

/// Saves an SSH host — created or rewritten — with the `ssh:<id>`
/// environment it owns, in one transaction. Refused for a host out of shape
/// (`sshHostProblem`). Answers the host as saved.
final class SshHostPut extends DataRequest<SshHost> {
  const SshHostPut(this.host);

  static const String name = 'sshHosts.put';

  final SshHost host;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'host': sshHostToJson(host)};

  @override
  Object? resultToJson(SshHost result) => sshHostToJson(result);

  @override
  SshHost resultFromJson(Object? json) =>
      _decode(kind, () => sshHostFromJson(_object(json, kind)));
}

/// Removes an SSH host and its environment. The host key trusted for it is
/// kept: dropping it would make a later re-add a silent re-trust. Refused
/// [DataRefusalCode.invalid], naming them, while projects still use it.
final class SshHostDelete extends _AckRequest {
  const SshHostDelete(this.id);

  static const String name = 'sshHosts.delete';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};
}

/// Trusts a host key a person accepted. **Refused when a different key is
/// already trusted for its `host:port`** (`trustProblem`) — a changed key is
/// never overwritten by a trust; the server stamps the time.
final class KnownHostTrust extends DataRequest<KnownHostKey> {
  const KnownHostTrust(this.key);

  static const String name = 'knownHosts.trust';

  final KnownHostKey key;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'key': knownHostToJson(key)};

  @override
  Object? resultToJson(KnownHostKey result) => knownHostToJson(result);

  @override
  KnownHostKey resultFromJson(Object? json) =>
      _decode(kind, () => knownHostFromJson(_object(json, kind)));
}

/// Forgets the key trusted for `host:port`, so the next connection is a
/// first connection again — the deliberate escape hatch for a rebuilt host.
final class KnownHostForget extends _AckRequest {
  const KnownHostForget(this.host, this.port);

  static const String name = 'knownHosts.forget';

  final String host;
  final int port;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'host': host, 'port': port};
}

// The agents: installations, saved accounts, usage history.

/// Every installation, and the saved accounts without their credentials.
final class AgentsList extends DataRequest<AgentsSnapshot> {
  const AgentsList();

  static const String name = 'agents.list';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(AgentsSnapshot result) => result.toJson();

  @override
  AgentsSnapshot resultFromJson(Object? json) =>
      _decode(kind, () => AgentsSnapshot.fromJson(_object(json, kind)));
}

/// Reconciles what a probe of [environmentId] [found] with its recorded
/// installations (`planReconcile`): [probed] names the agents it asked
/// about — only their leftover rows are judged — and [readings] what this
/// client's disk says of each row's path. Rows not found are removed only
/// when nothing points at them. Answers what the sweep established.
final class InstallationsReconcile
    extends DataRequest<InstallationsReconciled> {
  const InstallationsReconcile({
    required this.environmentId,
    required this.readAt,
    this.found = const [],
    this.probed = const {},
    this.readings = const {},
  });

  factory InstallationsReconcile._from(_Arguments args) {
    final readings = args.values['readings'] ?? const <String, Object?>{};
    if (readings is! Map) {
      throw DataRefused.invalid('$name: "readings" must map ids to readings');
    }
    try {
      return InstallationsReconcile(
        environmentId: args.string('environmentId'),
        readAt: args.date('readAt'),
        found: args.objects('found', installationFromJson),
        probed: args.strings('probed', orEmpty: true).toSet(),
        readings: {
          for (final entry in readings.entries)
            entry.key as String: reachabilityFromJson(entry.value),
        },
      );
    } on FormatException catch (error) {
      throw DataRefused.invalid('$name: ${error.message}');
    } on TypeError {
      throw DataRefused.invalid('$name: "readings" must map ids to readings');
    }
  }

  static const String name = 'installations.reconcile';

  final String environmentId;
  final DateTime readAt;
  final List<AgentInstallation> found;
  final Set<String> probed;
  final Map<String, ExecutableReachability> readings;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'environmentId': environmentId,
    'readAt': readAt.toUtc().toIso8601String(),
    'found': [for (final f in found) installationToJson(f)],
    'probed': [...probed],
    'readings': {
      for (final entry in readings.entries)
        entry.key: reachabilityToJson(entry.value),
    },
  };

  @override
  Object? resultToJson(InstallationsReconciled result) => result.toJson();

  @override
  InstallationsReconciled resultFromJson(Object? json) => _decode(
    kind,
    () => InstallationsReconciled.fromJson(_object(json, kind)),
  );
}

/// Records what the CLI of installation [id] answered, and when it was
/// asked — a confirmed reading is a fresh reading.
final class InstallationVersion extends _InstallationWrite {
  const InstallationVersion({
    required this.id,
    required this.version,
    required this.readAt,
  });

  static const String name = 'installations.recordVersion';

  final String id;
  final String version;
  final DateTime readAt;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'id': id,
    'version': version,
    'readAt': readAt.toUtc().toIso8601String(),
  };
}

/// Points installation [id] at [path], as a person chose it — a sweep will
/// not move it. Refused [DataRefusalCode.invalid] for a blank path, and for
/// one another row of the same agent there already holds.
final class InstallationSetPath extends _InstallationWrite {
  const InstallationSetPath({required this.id, required this.path});

  static const String name = 'installations.setPath';

  final String id;
  final String path;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id, 'path': path};
}

/// Saves a Claude account captured from an installation — the one with the
/// same email and organization is rewritten, keeping its id. Answers it
/// **without its credentials**.
final class ClaudeAccountSave extends DataRequest<ClaudeAccount> {
  const ClaudeAccountSave(this.account);

  static const String name = 'claudeAccounts.save';

  final ClaudeAccount account;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'account': claudeAccountToJson(account, credentials: true),
  };

  @override
  Object? resultToJson(ClaudeAccount result) => claudeAccountToJson(result);

  @override
  ClaudeAccount resultFromJson(Object? json) =>
      _decode(kind, () => claudeAccountFromJson(_object(json, kind)));
}

/// Saved Claude account [id] **with** its credentials — asked right before
/// an installation is switched to it, answered to the asking client alone
/// and never told as a change.
final class ClaudeAccountCredentials extends DataRequest<ClaudeAccount> {
  const ClaudeAccountCredentials(this.id);

  static const String name = 'claudeAccounts.credentials';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};

  @override
  Object? resultToJson(ClaudeAccount result) =>
      claudeAccountToJson(result, credentials: true);

  @override
  ClaudeAccount resultFromJson(Object? json) =>
      _decode(kind, () => claudeAccountFromJson(_object(json, kind)));
}

/// Forgets a saved Claude account (no installation's files are touched).
final class ClaudeAccountDelete extends _AckRequest {
  const ClaudeAccountDelete(this.id);

  static const String name = 'claudeAccounts.delete';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};
}

/// Saves a Codex account — the one with the same account id is rewritten,
/// keeping its id. Answers it **without its credentials**.
final class CodexAccountSave extends DataRequest<CodexAccount> {
  const CodexAccountSave(this.account);

  static const String name = 'codexAccounts.save';

  final CodexAccount account;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'account': codexAccountToJson(account, credentials: true),
  };

  @override
  Object? resultToJson(CodexAccount result) => codexAccountToJson(result);

  @override
  CodexAccount resultFromJson(Object? json) =>
      _decode(kind, () => codexAccountFromJson(_object(json, kind)));
}

/// Saved Codex account [id] **with** its credentials, for a switch.
final class CodexAccountCredentials extends DataRequest<CodexAccount> {
  const CodexAccountCredentials(this.id);

  static const String name = 'codexAccounts.credentials';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};

  @override
  Object? resultToJson(CodexAccount result) =>
      codexAccountToJson(result, credentials: true);

  @override
  CodexAccount resultFromJson(Object? json) =>
      _decode(kind, () => codexAccountFromJson(_object(json, kind)));
}

final class CodexAccountDelete extends _AckRequest {
  const CodexAccountDelete(this.id);

  static const String name = 'codexAccounts.delete';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};
}

/// Records one usage reading, as candidate samples (`usageSamplesOf`): the
/// server keeps those worth a row (`usageSampleWorthKeeping`) and prunes
/// the history as it goes. Answers how many rows were written.
final class UsageRecord extends DataRequest<int> {
  const UsageRecord(this.samples);

  static const String name = 'usage.record';

  final List<UsageSample> samples;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'samples': [for (final s in samples) usageSampleToJson(s)],
  };

  @override
  Object? resultToJson(int result) => result;

  @override
  int resultFromJson(Object? json) => json is int ? json : _badAnswer(kind);
}

/// Every sample of [accountKey] recorded at or after [since], oldest first.
final class UsageHistory extends DataRequest<List<UsageSample>> {
  const UsageHistory(this.accountKey, this.since);

  static const String name = 'usage.history';

  final String accountKey;
  final DateTime since;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'accountKey': accountKey,
    'since': since.toUtc().toIso8601String(),
  };

  @override
  Object? resultToJson(List<UsageSample> result) => [
    for (final sample in result) usageSampleToJson(sample),
  ];

  @override
  List<UsageSample> resultFromJson(Object? json) => _decode(kind, () {
    return [for (final item in _objects(json, kind)) usageSampleFromJson(item)];
  });
}

/// A request answered with the installation it wrote.
sealed class _InstallationWrite extends DataRequest<AgentInstallation> {
  const _InstallationWrite();

  @override
  Object? resultToJson(AgentInstallation result) => installationToJson(result);

  @override
  AgentInstallation resultFromJson(Object? json) =>
      _decode(kind, () => installationFromJson(_object(json, kind)));
}
