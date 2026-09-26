import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_environments/karmashala_environments.dart';

import 'agent_work_values.dart';

/// Where agents run, as one snapshot: the execution environments, the saved
/// SSH hosts (each with its key's location — the asking client's alone) and
/// the host keys trusted for them.
final class EnvironmentsSnapshot {
  const EnvironmentsSnapshot({
    this.environments = const [],
    this.sshHosts = const [],
    this.knownHosts = const [],
  });

  final List<ExecutionEnvironment> environments;
  final List<SshHost> sshHosts;
  final List<KnownHostKey> knownHosts;

  Map<String, Object?> toJson() => {
    'environments': [for (final e in environments) environmentToJson(e)],
    'sshHosts': [for (final h in sshHosts) sshHostToJson(h)],
    'knownHosts': [for (final k in knownHosts) knownHostToJson(k)],
  };

  static EnvironmentsSnapshot fromJson(Map<String, Object?> json) =>
      EnvironmentsSnapshot(
        environments: _list(json['environments'], environmentFromJson),
        sshHosts: _list(json['sshHosts'], sshHostFromJson),
        knownHosts: _list(json['knownHosts'], knownHostFromJson),
      );
}

/// The agents, as one snapshot: every installation, and the saved accounts
/// **without their credentials** — a token bundle is answered only to the
/// client that asks for it to switch an installation.
final class AgentsSnapshot {
  const AgentsSnapshot({
    this.installations = const [],
    this.claudeAccounts = const [],
    this.codexAccounts = const [],
    this.usage = const [],
  });

  final List<AgentInstallation> installations;
  final List<ClaudeAccount> claudeAccounts;
  final List<CodexAccount> codexAccounts;

  /// Every account's usage as the server last read it (`usage.current`).
  final List<AccountUsageState> usage;

  Map<String, Object?> toJson() => {
    'installations': [for (final i in installations) installationToJson(i)],
    'claudeAccounts': [for (final a in claudeAccounts) claudeAccountToJson(a)],
    'codexAccounts': [for (final a in codexAccounts) codexAccountToJson(a)],
    'usage': [for (final u in usage) u.toJson()],
  };

  static AgentsSnapshot fromJson(Map<String, Object?> json) => AgentsSnapshot(
    installations: _list(json['installations'], installationFromJson),
    claudeAccounts: _list(json['claudeAccounts'], claudeAccountFromJson),
    codexAccounts: _list(json['codexAccounts'], codexAccountFromJson),
    usage: json['usage'] == null
        ? const []
        : _list(json['usage'], AccountUsageState.fromJson),
  );
}

List<T> _list<T>(Object? json, T Function(Map<String, Object?>) read) =>
    json is List
    ? [
        for (final item in json)
          item is Map
              ? read(item.cast<String, Object?>())
              : throw const FormatException('expected an object'),
      ]
    : throw const FormatException('expected a list');
