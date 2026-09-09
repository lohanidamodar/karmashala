import 'dart:convert';
import 'dart:io';

import 'package:karmashala_core/util.dart';
import '../../cli_detection/application/cli_detection_service.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/execution_environment.dart';
import '../domain/agent_installation.dart';
import '../domain/codex_account.dart';

class CodexAuthException implements Exception {
  CodexAuthException(this.message);
  final String message;

  @override
  String toString() => 'CodexAuthException: $message';
}

class CodexAuthLocator {
  CodexAuthLocator(this._stores);
  final CliStoreLocator _stores;

  Future<String?> authPathFor(
    AgentInstallation installation,
    List<ExecutionEnvironment> environments,
  ) async {
    for (final store in await _stores.locate(environments)) {
      if (store.environmentId != installation.environmentId ||
          store.codexHome == null) {
        continue;
      }
      final kind = environments
          .where((e) => e.id == store.environmentId)
          .map((e) => e.kind)
          .firstOrNull;
      return storePathContextFor(kind).join(store.codexHome!, 'auth.json');
    }
    return null;
  }
}

/// Reads and captures Codex's own credential file without making a network
/// request. JWT payloads are decoded for display only; signatures are not
/// treated as proof because Codex, not Karmashala, authenticated the file.
class CodexAuthService {
  const CodexAuthService({required this.ids, required this.clock});

  final IdGenerator ids;
  final Clock clock;

  static const _backupSuffix = '.karmashala.bak';
  static const _tmpSuffix = '.karmashala.tmp';

  Future<CodexAuthSnapshot> readSnapshot(
    String path,
    String environmentId,
  ) async {
    final auth = await _read(path);
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

  Future<CodexAccount> capture(String path, String environmentId) async {
    final auth = await _read(path);
    if (auth == null) {
      throw CodexAuthException('No Codex credentials found at $path.');
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
  /// backed up once and the new JSON is renamed into place atomically.
  Future<void> switchTo(CodexAccount account, String path) async {
    final tokens = account.auth['tokens'];
    if (tokens is! Map<String, dynamic>) {
      throw CodexAuthException(
        'The captured Codex account has no usable token bundle.',
      );
    }
    final file = File(path);
    final current = await _readForSwitch(file);
    current['tokens'] = tokens;

    final backup = File('$path$_backupSuffix');
    if (!await backup.exists() && await file.exists()) {
      await file.copy(backup.path);
    }
    final staged = File('$path$_tmpSuffix');
    try {
      await staged.writeAsString('${jsonEncode(current)}\n', flush: true);
      await staged.rename(path);
    } catch (error) {
      if (await staged.exists()) await staged.delete();
      throw CodexAuthException('Could not switch Codex account: $error');
    }
  }

  Future<Map<String, dynamic>> _readForSwitch(File file) async {
    if (!await file.exists()) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException catch (error) {
      throw CodexAuthException(
        'Cannot switch accounts because ${file.path} is not valid JSON '
        '(${error.message}).',
      );
    }
    throw CodexAuthException(
      'Cannot switch accounts because ${file.path} is not a JSON object.',
    );
  }

  Future<Map<String, dynamic>?> _read(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } on Object {
      return null;
    }
  }
}

({String? accountId, String? email, String? planType, DateTime? expiresAt})
_identity(Map<String, dynamic> auth) {
  final tokens = auth['tokens'];
  if (tokens is! Map<String, dynamic>) {
    return (accountId: null, email: null, planType: null, expiresAt: null);
  }
  final claims = _jwtClaims(tokens['id_token']) ??
      _jwtClaims(tokens['access_token']) ??
      const <String, dynamic>{};
  final openAi = claims['https://api.openai.com/auth'];
  final details = openAi is Map ? openAi : const <Object?, Object?>{};
  final accountId = tokens['account_id'] as String? ??
      details['chatgpt_account_id'] as String?;
  final exp = claims['exp'];
  return (
    accountId: accountId,
    email: claims['email'] as String?,
    planType: details['chatgpt_plan_type'] as String?,
    expiresAt: exp is num
        ? DateTime.fromMillisecondsSinceEpoch(
            exp.toInt() * 1000,
            isUtc: true,
          )
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
