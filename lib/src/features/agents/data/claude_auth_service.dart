import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/logging/app_logger.dart';
import '../../../core/util/clock.dart';
import '../../../core/util/id_generator.dart';
import '../../../core/util/json_object_splice.dart';
import '../../cli_detection/application/cli_detection_service.dart';
import '../../environments/domain/execution_environment.dart';
import '../domain/agent_installation.dart';
import '../domain/agent_kind.dart';
import '../domain/claude_account.dart';
import '../domain/claude_auth_snapshot.dart';

/// The two files Claude Code persists per installation: the OAuth token bundle
/// and the identity/config record.
class ClaudeAuthPaths {
  const ClaudeAuthPaths({
    required this.environmentId,
    required this.credentialsFile,
    required this.configFile,
  });

  /// `<home>/.claude/.credentials.json` — holds `claudeAiOauth`.
  final String credentialsFile;

  /// `<home>/.claude.json` — holds `oauthAccount` (and much project state).
  final String configFile;

  final String environmentId;
}

/// Raised when capturing or switching a Claude account cannot proceed.
class ClaudeAuthException implements Exception {
  ClaudeAuthException(this.message);
  final String message;
  @override
  String toString() => 'ClaudeAuthException: $message';
}

/// Resolves the credential/config file locations for a Claude installation by
/// reusing [CliStoreLocator], which already maps each environment's `.claude`
/// home to a Windows-reachable path (`%USERPROFILE%` for Windows, the
/// `\\wsl.localhost\…` UNC form for WSL).
class ClaudeAuthLocator {
  ClaudeAuthLocator(this._storeLocator);

  final CliStoreLocator _storeLocator;

  /// Returns the paths for [installation], or `null` if the environment's
  /// `.claude` home could not be resolved.
  Future<ClaudeAuthPaths?> pathsFor(
    AgentInstallation installation,
    List<ExecutionEnvironment> environments,
  ) async {
    final stores = await _storeLocator.locate(environments);
    for (final store in stores) {
      if (store.environmentId != installation.environmentId) continue;
      final claudeHome = store.claudeHome;
      if (claudeHome == null) return null;
      return ClaudeAuthPaths(
        environmentId: store.environmentId,
        credentialsFile: p.windows.join(claudeHome, '.credentials.json'),
        // `.claude.json` sits next to the `.claude` directory, in the home dir.
        configFile: p.windows.join(
          p.windows.dirname(claudeHome),
          '.claude.json',
        ),
      );
    }
    return null;
  }
}

/// Reads, captures, and switches Claude Code accounts by manipulating the
/// credential and config files directly.
///
/// Writes are atomic (temp file + rename) and take a one-time `.chitragupta.bak`
/// backup of each file before the first modification, so a botched switch can
/// always be recovered. Token values are never logged.
class ClaudeAuthService {
  ClaudeAuthService({required this.ids, required this.clock, AppLogger? logger})
    : _logger = logger ?? AppLogger.named('claude-auth');

  final IdGenerator ids;
  final Clock clock;
  final AppLogger _logger;

  static const _backupSuffix = '.chitragupta.bak';
  static const _tmpSuffix = '.chitragupta.tmp';

  /// Reads the live logged-in account for the installation at [paths].
  Future<ClaudeAuthSnapshot> readSnapshot(ClaudeAuthPaths paths) async {
    final credentials = await _readJsonFile(paths.credentialsFile);
    final config = await _readJsonFile(paths.configFile);
    return parseClaudeSnapshot(
      environmentId: paths.environmentId,
      credentials: credentials,
      config: config,
    );
  }

  /// Captures the currently logged-in account at [paths] into a [ClaudeAccount].
  ///
  /// Throws [ClaudeAuthException] if no usable credentials/identity are present.
  Future<ClaudeAccount> capture(ClaudeAuthPaths paths) async {
    final credentials = await _readJsonFile(paths.credentialsFile);
    final config = await _readJsonFile(paths.configFile);

    final oauth = credentials?['claudeAiOauth'];
    if (oauth is! Map<String, dynamic>) {
      throw ClaudeAuthException(
        'No Claude credentials found at ${paths.credentialsFile}.',
      );
    }
    final account = config?['oauthAccount'];
    final email = account is Map<String, dynamic>
        ? account['emailAddress'] as String?
        : null;
    if (email == null || email.isEmpty) {
      throw ClaudeAuthException(
        'Could not determine the account email (no oauthAccount in '
        '${paths.configFile}). Sign in with `claude` once, then capture.',
      );
    }

    final oauthAccount = account as Map<String, dynamic>;
    return ClaudeAccount(
      id: ids.newId(),
      email: email,
      claudeAiOauth: oauth,
      oauthAccount: oauthAccount,
      organizationUuid: oauthAccount['organizationUuid'] as String?,
      organizationName: oauthAccount['organizationName'] as String?,
      subscriptionType: oauth['subscriptionType'] as String?,
      rateLimitTier: (oauth['rateLimitTier'] as String?) ??
          (oauthAccount['organizationRateLimitTier'] as String?),
      capturedEnvironmentId: paths.environmentId,
      capturedAt: clock.nowUtc(),
    );
  }

  /// Writes [account]'s tokens and identity into the installation at [paths],
  /// making it the logged-in account. Preserves everything else in both files
  /// (other credential keys such as MCP tokens, and all of `.claude.json`).
  Future<void> switchTo(ClaudeAccount account, ClaudeAuthPaths paths) async {
    // --- credentials: swap only claudeAiOauth ---
    final existingCreds =
        await _readJsonFile(paths.credentialsFile) ?? <String, dynamic>{};
    existingCreds['claudeAiOauth'] = account.claudeAiOauth;
    await _backupOnce(paths.credentialsFile);
    await _writeAtomic(paths.credentialsFile, jsonEncode(existingCreds));

    // --- config: splice only oauthAccount, if we have one to write ---
    final oauthAccount = account.oauthAccount;
    if (oauthAccount != null) {
      final configFile = File(paths.configFile);
      if (await configFile.exists()) {
        final raw = await configFile.readAsString();
        final updated = replaceTopLevelJsonValue(
          raw,
          'oauthAccount',
          jsonEncode(oauthAccount),
        );
        await _backupOnce(paths.configFile);
        await _writeAtomic(paths.configFile, updated);
      } else {
        await _writeAtomic(
          paths.configFile,
          '${jsonEncode({'oauthAccount': oauthAccount})}\n',
        );
      }
    }

    _logger.info(
      'Switched ${paths.environmentId} Claude account to ${account.email}.',
    );
  }

  // --- IO helpers ------------------------------------------------------------

  Future<Map<String, dynamic>?> _readJsonFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _backupOnce(String path) async {
    final backup = File('$path$_backupSuffix');
    if (await backup.exists()) return;
    final original = File(path);
    if (await original.exists()) await original.copy(backup.path);
  }

  Future<void> _writeAtomic(String path, String content) async {
    final tmp = File('$path$_tmpSuffix');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(path);
  }
}

/// Whether [installation] is a Claude Code installation (the only kind account
/// switching supports for now).
bool isClaudeInstallation(AgentInstallation installation) =>
    installation.agentKind == AgentKind.claudeCode;

/// Builds a [ClaudeAuthSnapshot] from decoded credential/config maps. Pure.
ClaudeAuthSnapshot parseClaudeSnapshot({
  required String environmentId,
  Map<String, dynamic>? credentials,
  Map<String, dynamic>? config,
}) {
  final oauth = credentials?['claudeAiOauth'];
  final account = config?['oauthAccount'];
  final oauthMap = oauth is Map<String, dynamic> ? oauth : null;
  final accountMap = account is Map<String, dynamic> ? account : null;

  final email = accountMap?['emailAddress'] as String?;
  if (email == null || email.isEmpty) {
    return ClaudeAuthSnapshot.signedOut(environmentId);
  }

  DateTime? expiresAt;
  final expiresRaw = oauthMap?['expiresAt'];
  if (expiresRaw is num) {
    expiresAt = DateTime.fromMillisecondsSinceEpoch(expiresRaw.toInt());
  }

  return ClaudeAuthSnapshot(
    environmentId: environmentId,
    email: email,
    organizationName: accountMap?['organizationName'] as String?,
    organizationUuid: accountMap?['organizationUuid'] as String?,
    subscriptionType: oauthMap?['subscriptionType'] as String?,
    rateLimitTier: (oauthMap?['rateLimitTier'] as String?) ??
        (accountMap?['organizationRateLimitTier'] as String?),
    accessTokenExpiresAt: expiresAt,
  );
}
