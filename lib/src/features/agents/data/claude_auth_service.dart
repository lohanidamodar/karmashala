import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_core/util.dart';
import '../../cli_detection/application/cli_detection_service.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/execution_environment.dart';
import '../../sessions/domain/session_resume.dart' show describeAge;
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
    Future<ClaudeKeychainRead> Function()? readKeychain,
  }) : _logger = logger ?? AppLogger.named('claude-auth'),
       _readKeychain = readKeychain ?? _readLoginKeychain;

  final IdGenerator ids;
  final Clock clock;
  final AppLogger _logger;

  /// One read of the macOS login Keychain — the secret *or why there is none*.
  ///
  /// The whole [ClaudeKeychainRead] rather than the secret, because the two
  /// ways of having no secret need two different answers and a `String?` can
  /// only carry one of them. A seam so tests need no Keychain, and so a future
  /// host with another credential store can be given one without touching the
  /// parsing.
  final Future<ClaudeKeychainRead> Function() _readKeychain;

  /// The service name Claude Code files its OAuth blob under.
  static const keychainService = 'Claude Code-credentials';

  static Future<ClaudeKeychainRead> _readLoginKeychain() =>
      claudeKeychain.read();

  static const _backupSuffix = '.karmashala.bak';
  static const _tmpSuffix = '.karmashala.tmp';

  /// Reads the live logged-in account for the installation at [paths].
  ///
  /// A Keychain **refusal** comes back as a signed-out snapshot that says so
  /// in [ClaudeAuthSnapshot.keychainRefusal], rather than as a thrown error.
  /// That is deliberate, and measured: `claudeAuthSnapshotProvider` is a
  /// `FutureProvider`, and Riverpod retries a provider that ends in an error —
  /// so raising here left the panel on "Reading current account…" for ever and
  /// asked macOS again on a backoff, which is the Keychain-dialog-per-poll
  /// that [ClaudeKeychainCache] exists to stop. A reading that carries what it
  /// could not do travels; an exception does not.
  Future<ClaudeAuthSnapshot> readSnapshot(ClaudeAuthPaths paths) async {
    final read = paths.credentialsInKeychain ? await _readKeychain() : null;
    if (read != null && read.outcome == ClaudeKeychainOutcome.refused) {
      return ClaudeAuthSnapshot.signedOut(
        paths.environmentId,
        keychainRefusal: claudeKeychainRefusalMessage(
          read,
          now: clock.nowUtc(),
        ),
      );
    }
    final credentials = read != null
        ? _decodeKeychain(read.secret)
        : await _readJsonFile(paths.credentialsFile);
    final config = await _readJsonFile(paths.configFile);
    return parseClaudeSnapshot(
      environmentId: paths.environmentId,
      credentials: credentials,
      config: config,
    );
  }

  /// The `claudeAiOauth` blob as the Keychain holds it.
  ///
  /// The Keychain holds exactly what the file holds elsewhere — the same
  /// `{"claudeAiOauth": {...}}` object — so everything downstream is unchanged.
  Map<String, dynamic>? _decodeKeychain(String? raw) {
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
    // Through the Keychain where the Keychain is where they live. Reading the
    // file on a Mac reported "No Claude credentials found at
    // ~/.claude/.credentials.json" — a path Claude Code never writes — for
    // both of the two things that can go wrong, and neither of them is a
    // missing file.
    final read = paths.credentialsInKeychain ? await _readKeychain() : null;
    if (read != null && read.outcome == ClaudeKeychainOutcome.refused) {
      throw ClaudeAuthException(
        claudeKeychainRefusalMessage(read, now: clock.nowUtc()),
      );
    }
    final credentials = read != null
        ? _decodeKeychain(read.secret)
        : await _readJsonFile(paths.credentialsFile);
    final config = await _readJsonFile(paths.configFile);

    final oauth = credentials?['claudeAiOauth'];
    if (oauth is! Map<String, dynamic>) {
      throw ClaudeAuthException(
        read != null
            // The store had nothing, which is a signed-out Mac and nothing
            // worse.
            ? 'Nothing is stored under "$keychainService" in the login '
                  'Keychain, so no Claude account is signed in here. Sign in '
                  'with `claude` once, then capture.'
            : 'No Claude credentials found at ${paths.credentialsFile}.',
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

/// Why a Keychain read produced no secret.
///
/// The distinction is the whole reason this type exists. A missing item means
/// nobody has logged in; a refusal means the credential is right there and
/// macOS would not hand it over — usually because the user answered the access
/// prompt with *Deny*, sometimes because the login Keychain is locked. Folding
/// the two together produced "Not signed in to Claude in this environment" in
/// front of users who were plainly signed in.
enum ClaudeKeychainOutcome {
  /// The secret was returned.
  found,

  /// `security` exited 44 — no such item. Verified against the real tool on
  /// macOS 25.5: a missing service prints "The specified item could not be
  /// found in the keychain." and exits 44, while a present one exits 0.
  notFound,

  /// Anything else: denied, locked, or `security` itself failing.
  refused,
}

/// One read of the Keychain: the secret, or why there isn't one.
@immutable
class ClaudeKeychainRead {
  const ClaudeKeychainRead(
    this.outcome, {
    this.secret,
    this.detail,
    this.readAt,
  });

  const ClaudeKeychainRead.notFound() : this(ClaudeKeychainOutcome.notFound);

  final ClaudeKeychainOutcome outcome;

  /// The credential. Never logged, never put in a message.
  final String? secret;

  /// `security`'s own words, for a message the user can act on. Only ever set
  /// on [ClaudeKeychainOutcome.refused], where the secret was not produced.
  final String? detail;

  /// When macOS was actually asked, or null when nobody has asked yet.
  ///
  /// Stamped once, by [ClaudeKeychainCache], and kept for the life of the
  /// memo — so a refusal shown ten minutes later says it is ten minutes old
  /// rather than pretending to be a fresh reading.
  final DateTime? readAt;

  ClaudeKeychainRead stampedAt(DateTime at) => ClaudeKeychainRead(
    outcome,
    secret: secret,
    detail: detail,
    readAt: at,
  );
}

/// What a refusal says, in one place, because more than one surface shows it:
/// the usage chip raises it, `capture` puts it in a snackbar, and a snapshot
/// carries it.
String claudeKeychainRefusalMessage(
  ClaudeKeychainRead read, {
  required DateTime now,
}) {
  final detail = read.detail;
  final at = read.readAt;
  final age = at == null
      ? 'at an unknown time'
      : describeAge(now.difference(at));
  return 'macOS would not release the Claude credential from the login '
      'Keychain'
      '${detail == null ? '' : ' ($detail)'}'
      ' — asked $age. That is a refusal, not a signed-out account: allow '
      'Karmashala access to "${ClaudeAuthService.keychainService}" in '
      'Keychain Access.';
}

/// The process-wide memo of the Keychain read.
///
/// Every fetch used to spawn `security find-generic-password`, and the status
/// bar's quota chip polls once a minute while the window is focused. On a Mac
/// where the user answered the access prompt with *Allow* rather than *Always
/// Allow*, that is a Keychain dialog a minute — the app asking, over and over,
/// for something it already had.
///
/// **Refusals are cached too, and that is deliberate.** Caching only successes
/// would leave the one case that actually raises a dialog re-asking on every
/// tick, which is the bug. A user who fixes the grant waits out the window
/// rather than being interrogated during it.
///
/// The window is long against the poll and short against a working session, so
/// a re-login is picked up without anyone restarting the app. A token that goes
/// stale sooner than that is handled where it is noticed: the usage endpoint
/// 401s, and that path calls [forget] and reads again.
class ClaudeKeychainCache {
  ClaudeKeychainCache({
    Future<ClaudeKeychainRead> Function()? read,
    DateTime Function()? now,
    this.lifetime = const Duration(minutes: 10),
  }) : _read = read ?? _securityRead,
       // UTC, because the stamp is differenced against a [Clock]'s `nowUtc`
       // when a refusal is worded.
       _now = now ?? _utcNow;

  final Future<ClaudeKeychainRead> Function() _read;
  final DateTime Function() _now;
  final Duration lifetime;

  ClaudeKeychainRead? _cached;

  /// Reads through the memo, spawning `security` only when nothing fresh is
  /// held.
  ///
  /// The memo's own clock is the stamp on what it holds — one instant, kept
  /// where a caller can read it, rather than one for the lifetime and another
  /// for the message.
  Future<ClaudeKeychainRead> read() async {
    final held = _cached;
    final at = held?.readAt;
    if (held != null && at != null && _now().difference(at) < lifetime) {
      return held;
    }
    final fresh = (await _read()).stampedAt(_now());
    _cached = fresh;
    return fresh;
  }

  static DateTime _utcNow() => DateTime.now().toUtc();

  /// Drops what is held, so the next [read] asks macOS again.
  ///
  /// Called when the token we handed out was rejected: the copy we are holding
  /// is provably wrong at that point, whatever the clock says.
  void forget() => _cached = null;

  static Future<ClaudeKeychainRead> _securityRead() async {
    if (!Platform.isMacOS) return const ClaudeKeychainRead.notFound();
    try {
      final result = await Process.run('security', [
        'find-generic-password',
        '-s',
        ClaudeAuthService.keychainService,
        '-w',
      ]);
      return claudeKeychainReadOf(
        result.exitCode,
        stdout: result.stdout,
        stderr: result.stderr,
      );
    } on Object catch (error) {
      // The tool itself could not be run. Not a signed-out user.
      return ClaudeKeychainRead(
        ClaudeKeychainOutcome.refused,
        detail: '$error',
      );
    }
  }
}

/// What one `security find-generic-password -w` run meant.
///
/// Pure, and separate from the spawn, because the exit codes are the load
/// bearing part and a test cannot make macOS deny a prompt on demand. The codes
/// were read off the real tool on this machine (macOS 25.5): a present item
/// exits 0 and prints the secret, a missing service exits **44** with
/// "SecKeychainSearchCopyNext: The specified item could not be found in the
/// keychain."
ClaudeKeychainRead claudeKeychainReadOf(
  int exitCode, {
  Object? stdout,
  Object? stderr,
}) {
  const itemNotFound = 44;
  if (exitCode == 0) {
    final out = '$stdout'.trim();
    // An empty success is not a credential, and treating it as one would hand
    // the usage endpoint an empty bearer token.
    return out.isEmpty
        ? const ClaudeKeychainRead.notFound()
        : ClaudeKeychainRead(ClaudeKeychainOutcome.found, secret: out);
  }
  if (exitCode == itemNotFound) return const ClaudeKeychainRead.notFound();
  return ClaudeKeychainRead(
    ClaudeKeychainOutcome.refused,
    detail: _tidySecurityError(stderr),
  );
}

/// `security` prefixes its own name and the failing call; the tail is the only
/// part a user can act on.
String? _tidySecurityError(Object? stderr) {
  final text = '$stderr'.trim();
  if (text.isEmpty) return null;
  final last = text.split('\n').last.trim();
  final colon = last.lastIndexOf(': ');
  return colon == -1 ? last : last.substring(colon + 2);
}

/// The one memo the app reads through. Shared, because both account detection
/// and the usage endpoint need the same token and macOS keeps one copy of it.
final claudeKeychain = ClaudeKeychainCache();

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
