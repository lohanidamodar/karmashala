import 'dart:convert';
import 'dart:io';

import '../../../core/util/clock.dart';
import '../../../core/util/id_generator.dart';
import '../../cli_detection/application/cli_detection_service.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/execution_environment.dart';
import '../domain/agent_installation.dart';
import '../domain/codex_account.dart';

class CodexAuthException implements Exception {
  CodexAuthException(this.message);
  final String message;
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
