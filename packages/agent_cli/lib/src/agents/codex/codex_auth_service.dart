import 'dart:convert';

import '../../util/clock.dart';
import '../domain/agent_ids.dart';
import '../../util/id_generator.dart';
import '../../cli_detection/data/cli_store.dart';
import '../../environments/environment_kind.dart';
import '../../environments/execution_environment.dart';
import '../../process/command_runner.dart';
import '../domain/agent_installation.dart';
import './codex_account.dart';
import '../data/auth_file_io.dart';

export '../data/auth_file_io.dart';

class CodexAuthException implements Exception {
  CodexAuthException(this.message);
  final String message;

  @override
  String toString() => 'CodexAuthException: $message';
}

/// Where one installation's `auth.json` is, and how to reach it.
typedef CodexAuthLocation = ({String path, AuthFileIo io});

class CodexAuthLocator {
  CodexAuthLocator(this._stores);
  final CliStoreLocator _stores;

  final Map<String, RemoteAgentHomes> _remoteHomes = {};

  /// The path alone. See [locationFor], which also says how to reach it.
  Future<String?> authPathFor(
    AgentInstallation installation,
    List<ExecutionEnvironment> environments,
  ) async => (await locationFor(installation, environments))?.path;

  /// Where [installation]'s `auth.json` is and the [AuthFileIo] that reaches
  /// it, or null when its environment has no Codex home.
  ///
  /// An SSH environment's file is on the remote disk, which [CliStoreLocator]
  /// does not reach: it is asked of the host (`$CODEX_HOME`, or `~/.codex`)
  /// and read and written over that environment's runner. A host that cannot
  /// be asked still gets a location, whose [RefusingAuthFileIo] says why.
  Future<CodexAuthLocation?> locationFor(
    AgentInstallation installation,
    List<ExecutionEnvironment> environments,
  ) async {
    final remote = environments
        .where(
          (e) =>
              e.id == installation.environmentId &&
              e.kind == EnvironmentKind.ssh,
        )
        .firstOrNull;
    if (remote != null) return _remoteLocation(remote);

    for (final store in await _stores.locate(environments)) {
      if (store.environmentId != installation.environmentId ||
          store.homeFor(AgentIds.codex) == null) {
        continue;
      }
      final environment = environments
          .where((e) => e.id == store.environmentId)
          .firstOrNull;
      return (
        path: storePathContextFor(
          environment?.kind,
        ).join(store.homeFor(AgentIds.codex)!, 'auth.json'),
        io: environment == null
            ? const LocalAuthFileIo()
            : storeAuthFileIo(
                environment: environment,
                environments: environments,
                runnerFor: _stores.runnerFor,
                translator: _stores.translator,
              ),
      );
    }
    return null;
  }

  Future<CodexAuthLocation> _remoteLocation(
    ExecutionEnvironment environment,
  ) async {
    const unresolved = '~/.codex/auth.json';
    final CommandRunner runner;
    try {
      runner = _stores.runnerFor(environment.id);
    } on Object catch (e) {
      return (
        path: unresolved,
        io: RefusingAuthFileIo(
          'Karmashala has no connection to ${environment.name} ($e).',
        ),
      );
    }
    var homes = _remoteHomes[environment.id];
    if (homes == null) {
      try {
        homes = await resolveRemoteAgentHomes(
          runner,
          environmentName: environment.name,
        );
      } on AuthFileIoException catch (e) {
        // Not cached, so a host that comes back is picked up on the next read.
        return (path: unresolved, io: RefusingAuthFileIo(e.message));
      }
      _remoteHomes[environment.id] = homes;
    }
    return (
      path: homes.codexAuthFile,
      io: RemoteAuthFileIo(runner: runner, environmentName: environment.name),
    );
  }
}

/// Reads and captures Codex's own credential file without making a network
/// request. JWT payloads are decoded for display only; signatures are not
/// treated as proof because Codex, not Karmashala, authenticated the file.
///
/// Every method takes the [AuthFileIo] its [CodexAuthLocator] resolved; the
/// default, [LocalAuthFileIo], is what the Windows host uses.
class CodexAuthService {
  const CodexAuthService({required this.ids, required this.clock});

  final IdGenerator ids;
  final Clock clock;

  static const _backupSuffix = '.karmashala.bak';

  Future<CodexAuthSnapshot> readSnapshot(
    String path,
    String environmentId, {
    AuthFileIo io = const LocalAuthFileIo(),
  }) async {
    final read = await io.readJsonObject(path);
    if (read.failure case final failure?) {
      return CodexAuthSnapshot.signedOut(environmentId, readFailure: failure);
    }
    final auth = read.object;
    if (auth == null) return CodexAuthSnapshot.signedOut(environmentId);
    final identity = _identity(auth);
    if (identity.accountId == null) {
      return CodexAuthSnapshot.signedOut(environmentId);
    }
    return CodexAuthSnapshot(
      environmentId: environmentId,
      accountId: identity.accountId,
      email: identity.email,
      planType: identity.planType,
      accessTokenExpiresAt: identity.expiresAt,
    );
  }

  Future<CodexAccount> capture(
    String path,
    String environmentId, {
    AuthFileIo io = const LocalAuthFileIo(),
  }) async {
    final read = await io.readJsonObject(path);
    if (read.failure case final failure?) throw CodexAuthException(failure);
    final auth = read.object;
    if (auth == null) {
      throw CodexAuthException(
        'No Codex credentials found at ${io.describe(path)}.',
      );
    }
    final identity = _identity(auth);
    final accountId = identity.accountId;
    if (accountId == null) {
      throw CodexAuthException(
        'Could not determine the Codex account id. Run `codex login` first.',
      );
    }
    return CodexAccount(
      id: ids.newId(),
      accountId: accountId,
      email: identity.email,
      planType: identity.planType,
      auth: auth,
      capturedEnvironmentId: environmentId,
      capturedAt: clock.nowUtc(),
    );
  }

  /// Makes [account] active while preserving unrelated top-level auth fields.
  ///
  /// Codex owns `auth.json`; Karmashala owns none of its future keys. Only the
  /// token bundle captured for this account is replaced. The original is
  /// backed up once and the new JSON is renamed into place atomically — and,
  /// on an SSH host, written owner-only (see [RemoteAuthFileIo]).
  Future<void> switchTo(
    CodexAccount account,
    String path, {
    AuthFileIo io = const LocalAuthFileIo(),
  }) async {
    final tokens = account.auth['tokens'];
    if (tokens is! Map<String, dynamic>) {
      throw CodexAuthException(
        'The captured Codex account has no usable token bundle.',
      );
    }
    final current = await _readForSwitch(io, path);
    current['tokens'] = tokens;

    try {
      await io.backupOnce(path, '$path$_backupSuffix');
      await io.writeAtomic(path, '${jsonEncode(current)}\n', secret: true);
    } on AuthFileIoException catch (error) {
      throw CodexAuthException(
        'Could not switch Codex account: ${error.message}',
      );
    }
  }

  Future<Map<String, dynamic>> _readForSwitch(
    AuthFileIo io,
    String path,
  ) async {
    final String? raw;
    try {
      raw = await io.readText(path);
    } on AuthFileIoException catch (error) {
      throw CodexAuthException('Cannot switch accounts: ${error.message}');
    }
    if (raw == null) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException catch (error) {
      throw CodexAuthException(
        'Cannot switch accounts because $path is not valid JSON '
        '(${error.message}).',
      );
    }
    throw CodexAuthException(
      'Cannot switch accounts because $path is not a JSON object.',
    );
  }
}

({String? accountId, String? email, String? planType, DateTime? expiresAt})
_identity(Map<String, dynamic> auth) {
  final tokens = auth['tokens'];
  if (tokens is! Map<String, dynamic>) {
    return (accountId: null, email: null, planType: null, expiresAt: null);
  }
  final claims =
      _jwtClaims(tokens['id_token']) ??
      _jwtClaims(tokens['access_token']) ??
      const <String, dynamic>{};
  final openAi = claims['https://api.openai.com/auth'];
  final details = openAi is Map ? openAi : const <Object?, Object?>{};
  final accountId =
      tokens['account_id'] as String? ??
      details['chatgpt_account_id'] as String?;
  final exp = claims['exp'];
  return (
    accountId: accountId,
    email: claims['email'] as String?,
    planType: details['chatgpt_plan_type'] as String?,
    expiresAt: exp is num
        ? DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000, isUtc: true)
        : null,
  );
}

Map<String, dynamic>? _jwtClaims(Object? token) {
  if (token is! String) return null;
  final parts = token.split('.');
  if (parts.length < 2) return null;
  try {
    final decoded = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    return decoded is Map<String, dynamic> ? decoded : null;
  } on Object {
    return null;
  }
}
