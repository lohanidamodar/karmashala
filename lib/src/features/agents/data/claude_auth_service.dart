import 'dart:convert';
import 'dart:io';

import '../../../core/logging/app_logger.dart';
import '../../../core/util/clock.dart';
import '../../../core/util/id_generator.dart';
import '../../../core/util/json_object_splice.dart';
import '../../cli_detection/application/cli_detection_service.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/execution_environment.dart';
import '../domain/agent_installation.dart';
import '../domain/agent_ids.dart';
import '../domain/claude_account.dart';
import '../domain/claude_auth_snapshot.dart';

/// The two files Claude Code persists per installation: the OAuth token bundle
/// and the identity/config record.
class ClaudeAuthPaths {
  const ClaudeAuthPaths({
    required this.environmentId,
    required this.credentialsFile,
    required this.configFile,
    this.credentialsInKeychain = false,
  });

  /// `<home>/.claude/.credentials.json` — holds `claudeAiOauth`.
  ///
  /// Not written on macOS; see [credentialsInKeychain].
  final String credentialsFile;

  /// Whether `claudeAiOauth` lives in the login Keychain rather than in
  /// [credentialsFile].
  ///
  /// It does on macOS, where Claude Code keeps it as a generic password under
  /// the service name `Claude Code-credentials` and writes no credentials file
  /// at all. Reading only the file there found nothing — which, before the
  /// path bug below was fixed, was the second reason a plainly logged-in
  /// account reported itself signed out.
  final bool credentialsInKeychain;

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
/// home to a form this host can read — `%USERPROFILE%` for Windows, the
/// `\\wsl.localhost\…` UNC form for WSL, and an ordinary POSIX path on macOS
/// and Linux.
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
      final kind = environments
          .where((e) => e.id == store.environmentId)
          .map((e) => e.kind)
          .firstOrNull;
      // The separator has to match the path the store locator produced, which
      // is the same choice `CliStoreLocator` itself makes. Joining with the
      // Windows context unconditionally turned `/Users/me/.claude` into
      // `/Users/me\.claude.json` — a file that cannot exist, so the config read
      // came back null and every Mac account reported itself signed out.
      final ctx = storePathContextFor(kind);
      return ClaudeAuthPaths(
        environmentId: store.environmentId,
        credentialsFile: ctx.join(claudeHome, '.credentials.json'),
        // `.claude.json` sits next to the `.claude` directory, in the home dir.
        configFile: ctx.join(ctx.dirname(claudeHome), '.claude.json'),
        // Only the local Mac: a WSL or SSH environment keeps its own file, and
        // this host's Keychain has nothing to say about it.
        credentialsInKeychain:
            Platform.isMacOS && kind != null && isLocalHost(kind),
      );
    }
    return null;
  }
}

/// Reads, captures, and switches Claude Code accounts by manipulating the
/// credential and config files directly.
///
/// Writes are atomic (temp file + rename) and take a one-time `.karmashala.bak`
/// backup of each file before the first modification, so a botched switch can
/// always be recovered. Token values are never logged.
class ClaudeAuthService {
  ClaudeAuthService({
    required this.ids,
    required this.clock,
    AppLogger? logger,
    Future<String?> Function()? readKeychainCredentials,
  }) : _logger = logger ?? AppLogger.named('claude-auth'),
       _readKeychain = readKeychainCredentials ?? _securityFindGenericPassword;

  final IdGenerator ids;
  final Clock clock;
  final AppLogger _logger;

  /// Reads the raw credentials JSON out of the macOS login Keychain.
  ///
  /// A seam so tests need no Keychain, and so a future host with another
  /// credential store can be given one without touching the parsing.
  final Future<String?> Function() _readKeychain;

  /// The service name Claude Code files its OAuth blob under.
  static const keychainService = 'Claude Code-credentials';

  static Future<String?> _securityFindGenericPassword() =>
      readClaudeKeychainCredentials();

  static const _backupSuffix = '.karmashala.bak';
  static const _tmpSuffix = '.karmashala.tmp';

  /// Reads the live logged-in account for the installation at [paths].
  Future<ClaudeAuthSnapshot> readSnapshot(ClaudeAuthPaths paths) async {
    final credentials = await _readCredentials(paths);
    final config = await _readJsonFile(paths.configFile);
    return parseClaudeSnapshot(
      environmentId: paths.environmentId,
      credentials: credentials,
      config: config,
    );
  }

  /// The `claudeAiOauth` blob, from wherever this host keeps it.
  ///
  /// The Keychain holds exactly what the file holds elsewhere — the same
  /// `{"claudeAiOauth": {...}}` object — so everything downstream is unchanged.
  Future<Map<String, dynamic>?> _readCredentials(ClaudeAuthPaths paths) async {
    if (!paths.credentialsInKeychain) {
      return _readJsonFile(paths.credentialsFile);
    }
    final raw = await _readKeychain();
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      // Never log `raw`: it is the credential.
      _logger.warning('The Keychain credentials were not JSON.');
      return null;
    }
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
      rateLimitTier:
          (oauth['rateLimitTier'] as String?) ??
          (oauthAccount['organizationRateLimitTier'] as String?),
      capturedEnvironmentId: paths.environmentId,
      capturedAt: clock.nowUtc(),
    );
  }

  /// Writes [account]'s tokens and identity into the installation at [paths],
  /// making it the logged-in account. Preserves everything else in both files
  /// (other credential keys such as MCP tokens, and all of `.claude.json`).
  Future<void> switchTo(ClaudeAccount account, ClaudeAuthPaths paths) async {
    if (paths.credentialsInKeychain) {
      // Refused rather than half-done. The identity in `.claude.json` would be
      // rewritten and the tokens would not, because on macOS the tokens are in
      // the Keychain — leaving Claude Code authenticated as one account and
      // labelled as another, which is worse than not switching at all.
      throw ClaudeAuthException(
        'Switching accounts is not supported on macOS yet: Claude Code keeps '
        'its tokens in the login Keychain rather than in a file this can '
        'rewrite. Use `claude /login` to change account.',
      );
    }
    // Prepare every update before writing either file. In particular, a
    // malformed config must not leave the new token paired with the old
    // identity after the config splice fails.
    final existingCreds = await _readJsonFileForSwitch(paths.credentialsFile);
    existingCreds['claudeAiOauth'] = account.claudeAiOauth;

    final oauthAccount = account.oauthAccount;
    String? updatedConfig;
    var configExists = false;
    if (oauthAccount != null) {
      final configFile = File(paths.configFile);
      configExists = await configFile.exists();
      if (configExists) {
        final raw = await configFile.readAsString();
        try {
          updatedConfig = replaceTopLevelJsonValue(
            raw,
            'oauthAccount',
            jsonEncode(oauthAccount),
          );
        } on FormatException catch (e) {
          throw ClaudeAuthException(
            'Cannot switch accounts because ${paths.configFile} is not valid '
            'JSON (${e.message}).',
          );
        }
      } else {
        updatedConfig = '${jsonEncode({'oauthAccount': oauthAccount})}\n';
      }
    }

    // --- credentials: swap only claudeAiOauth ---
    await _backupOnce(paths.credentialsFile);
    await _writeAtomic(paths.credentialsFile, jsonEncode(existingCreds));

    // --- config: splice only oauthAccount, if we have one to write ---
    if (updatedConfig != null) {
      if (configExists) await _backupOnce(paths.configFile);
      await _writeAtomic(paths.configFile, updatedConfig);
    }

    _logger.info(
      'Switched ${paths.environmentId} Claude account to ${account.email}.',
    );
  }

  Future<Map<String, dynamic>> _readJsonFileForSwitch(String path) async {
    final file = File(path);
    if (!await file.exists()) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException catch (e) {
      throw ClaudeAuthException(
        'Cannot switch accounts because $path is not valid JSON (${e.message}).',
      );
    }
    throw ClaudeAuthException(
      'Cannot switch accounts because $path does not contain a JSON object.',
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

/// The raw credentials JSON out of the macOS login Keychain, or null.
///
/// `security find-generic-password -w` prints just the secret. Run directly
/// rather than through a [CommandRunner]: this is always the local Mac's own
/// Keychain, never an environment the runner could route to, and the value is a
/// credential that must not travel further than it has to. It is never logged.
///
/// Shared, because both account detection and the usage endpoint need the same
/// token and macOS keeps only one copy of it.
Future<String?> readClaudeKeychainCredentials() async {
  if (!Platform.isMacOS) return null;
  try {
    final result = await Process.run('security', [
      'find-generic-password',
      '-s',
      ClaudeAuthService.keychainService,
      '-w',
    ]);
    if (result.exitCode != 0) return null;
    final out = (result.stdout as String).trim();
    return out.isEmpty ? null : out;
  } on Object {
    return null;
  }
}

/// Whether [installation] is a Claude Code installation (the only agent account
/// switching supports for now).
bool isClaudeInstallation(AgentInstallation installation) =>
    installation.agentId == AgentIds.claudeCode;

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
    rateLimitTier:
        (oauthMap?['rateLimitTier'] as String?) ??
        (accountMap?['organizationRateLimitTier'] as String?),
    accessTokenExpiresAt: expiresAt,
  );
}
