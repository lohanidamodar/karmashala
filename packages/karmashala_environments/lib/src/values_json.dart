import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_projects/karmashala_projects.dart'
    show environmentPathFromJson, environmentPathToJson;

import 'ssh_host.dart';
import 'ssh_host_key.dart';

/// The wire shape of this domain's values. Each reader throws
/// [FormatException] on a value out of shape.
///
/// **Credentials never travel by default.** A saved account's token bundle
/// (`claudeAiOauth`, Codex's `auth.json`) is written only with
/// `credentials: true` — the one answer that carries it is the one a client
/// asks for right before it switches an installation to that account.

Map<String, Object?> environmentToJson(ExecutionEnvironment environment) => {
  'id': environment.id,
  'kind': environment.kind.name,
  'name': environment.name,
  'wslDistribution': ?environment.wslDistribution,
  'sshHostId': ?environment.sshHostId,
  'createdAt': _time(environment.createdAt),
};

ExecutionEnvironment environmentFromJson(Map<String, Object?> json) =>
    ExecutionEnvironment(
      id: _string(json, 'id'),
      kind: _enum(EnvironmentKind.values, json['kind']),
      name: _string(json, 'name'),
      wslDistribution: _optional(json, 'wslDistribution'),
      sshHostId: _optional(json, 'sshHostId'),
      createdAt: _date(json['createdAt']),
    );

/// [host] as the wire carries it. The private key's *location* (never a
/// key: the table has no column for one) is left out unless [withKeyPath] —
/// a client that asked for its hosts gets it; a change told to other clients
/// does not carry it.
Map<String, Object?> sshHostToJson(SshHost host, {bool withKeyPath = true}) => {
  'id': host.id,
  'name': host.name,
  'host': host.host,
  'port': host.port,
  'username': host.username,
  'authMethod': host.authMethod.name,
  if (withKeyPath && host.privateKey != null)
    'privateKey': environmentPathToJson(host.privateKey!),
  if (host.defaultDirectory != null)
    'defaultDirectory': environmentPathToJson(host.defaultDirectory!),
  'createdAt': _time(host.createdAt),
};

SshHost sshHostFromJson(Map<String, Object?> json) => SshHost(
  id: _string(json, 'id'),
  name: _string(json, 'name'),
  host: _string(json, 'host'),
  port: _int(json, 'port'),
  username: _string(json, 'username'),
  authMethod: _enum(SshAuthMethod.values, json['authMethod']),
  privateKey: json['privateKey'] == null
      ? null
      : environmentPathFromJson(json['privateKey']),
  defaultDirectory: json['defaultDirectory'] == null
      ? null
      : environmentPathFromJson(json['defaultDirectory']),
  createdAt: _date(json['createdAt']),
);

Map<String, Object?> knownHostToJson(KnownHostKey key) => {
  'host': key.host,
  'port': key.port,
  'keyType': key.keyType,
  'fingerprint': key.fingerprint,
  'trustedAt': _time(key.trustedAt),
};

KnownHostKey knownHostFromJson(Map<String, Object?> json) => KnownHostKey(
  host: _string(json, 'host'),
  port: _int(json, 'port'),
  keyType: _string(json, 'keyType'),
  fingerprint: _string(json, 'fingerprint'),
  trustedAt: _date(json['trustedAt']),
);

Map<String, Object?> installationToJson(AgentInstallation installation) => {
  'id': installation.id,
  'agentId': installation.agentId,
  'executable': environmentPathToJson(installation.executable),
  'version': ?installation.version,
  if (installation.versionReadAt != null)
    'versionReadAt': _time(installation.versionReadAt!),
  'createdAt': _time(installation.createdAt),
  'byUser': installation.executableByUser,
};

AgentInstallation installationFromJson(Map<String, Object?> json) =>
    AgentInstallation(
      id: _string(json, 'id'),
      agentId: _string(json, 'agentId'),
      executable: environmentPathFromJson(json['executable']),
      version: _optional(json, 'version'),
      versionReadAt: json['versionReadAt'] == null
          ? null
          : _date(json['versionReadAt']),
      createdAt: _date(json['createdAt']),
      executableByUser: json['byUser'] == true,
    );

/// [account] as the wire carries it: the token bundle and the identity
/// record only with [credentials].
Map<String, Object?> claudeAccountToJson(
  ClaudeAccount account, {
  bool credentials = false,
}) => {
  'id': account.id,
  'email': account.email,
  'organizationUuid': ?account.organizationUuid,
  'organizationName': ?account.organizationName,
  'subscriptionType': ?account.subscriptionType,
  'rateLimitTier': ?account.rateLimitTier,
  'capturedEnvironmentId': ?account.capturedEnvironmentId,
  'capturedAt': _time(account.capturedAt),
  if (credentials) 'claudeAiOauth': account.claudeAiOauth,
  if (credentials && account.oauthAccount != null)
    'oauthAccount': account.oauthAccount,
};

/// An account read without its credentials holds an empty token bundle.
ClaudeAccount claudeAccountFromJson(Map<String, Object?> json) => ClaudeAccount(
  id: _string(json, 'id'),
  email: _string(json, 'email'),
  organizationUuid: _optional(json, 'organizationUuid'),
  organizationName: _optional(json, 'organizationName'),
  subscriptionType: _optional(json, 'subscriptionType'),
  rateLimitTier: _optional(json, 'rateLimitTier'),
  capturedEnvironmentId: _optional(json, 'capturedEnvironmentId'),
  capturedAt: _date(json['capturedAt']),
  claudeAiOauth: _map(json['claudeAiOauth']) ?? const {},
  oauthAccount: _map(json['oauthAccount']),
);

Map<String, Object?> codexAccountToJson(
  CodexAccount account, {
  bool credentials = false,
}) => {
  'id': account.id,
  'accountId': account.accountId,
  'email': ?account.email,
  'planType': ?account.planType,
  'capturedEnvironmentId': ?account.capturedEnvironmentId,
  'capturedAt': _time(account.capturedAt),
  if (credentials) 'auth': account.auth,
};

CodexAccount codexAccountFromJson(Map<String, Object?> json) => CodexAccount(
  id: _string(json, 'id'),
  accountId: _string(json, 'accountId'),
  email: _optional(json, 'email'),
  planType: _optional(json, 'planType'),
  capturedEnvironmentId: _optional(json, 'capturedEnvironmentId'),
  capturedAt: _date(json['capturedAt']),
  auth: _map(json['auth']) ?? const {},
);

Map<String, Object?> usageSampleToJson(UsageSample sample) => {
  'accountKey': sample.accountKey,
  'window': sample.windowLabel,
  'percent': sample.percent,
  if (sample.span != null) 'spanSeconds': sample.span!.inSeconds,
  if (sample.resetsAt != null) 'resetsAt': _time(sample.resetsAt!),
  'recordedAt': _time(sample.recordedAt),
};

UsageSample usageSampleFromJson(Map<String, Object?> json) {
  final percent = json['percent'];
  final span = json['spanSeconds'];
  if (percent is! num || (span != null && span is! int)) {
    throw const FormatException('not a usage sample');
  }
  return UsageSample(
    accountKey: _string(json, 'accountKey'),
    windowLabel: _string(json, 'window'),
    percent: percent.toDouble(),
    span: span == null ? null : Duration(seconds: span as int),
    resetsAt: json['resetsAt'] == null ? null : _date(json['resetsAt']),
    recordedAt: _date(json['recordedAt']),
  );
}

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

T _enum<T extends Enum>(List<T> values, Object? name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException('not one of ${values.map((v) => v.name)}: $name');
}

Map<String, dynamic>? _map(Object? json) {
  if (json == null) return null;
  if (json is Map) return json.cast<String, dynamic>();
  throw const FormatException('expected an object');
}
