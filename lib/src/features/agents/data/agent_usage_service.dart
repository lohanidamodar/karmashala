import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/util/clock.dart';
import '../../cli_detection/application/cli_detection_service.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/execution_environment.dart';
import '../domain/agent_installation.dart';
import '../domain/agent_ids.dart';
import '../domain/agent_registry.dart';
import '../domain/agent_usage.dart';
import 'claude_auth_service.dart';
import '../../environments/domain/environment_label.dart';

/// Raised when a usage lookup cannot complete.
class UsageException implements Exception {
  UsageException(this.message);
  final String message;
  @override
  String toString() => 'UsageException: $message';
}

/// Fetches live usage/limit data for an agent installation from the same OAuth
/// endpoints the vendor apps use, authorized with the token the installation
/// already stores on disk.
///
/// - Claude Code: `GET https://api.anthropic.com/api/oauth/usage` with the
///   `claudeAiOauth.accessToken` from `.claude/.credentials.json`.
/// - Codex: `GET https://chatgpt.com/backend-api/wham/usage` with the
///   `tokens.access_token` from `.codex/auth.json`.
///
/// Tokens are only read (never written) and never logged. If the stored access
/// token has expired the request 401s; rather than refresh it ourselves (which
/// could disturb the CLI's own credentials), we surface a clear message telling
/// the user to run the agent once to refresh.
class AgentUsageService {
  AgentUsageService({
    required this.storeLocator,
    required this.clock,
    HttpClient Function()? httpClientFactory,
    ClaudeKeychainCache? keychain,
    bool? hostIsMacOS,
  }) : _newClient = httpClientFactory ?? HttpClient.new,
       _keychain = keychain ?? claudeKeychain,
       _hostIsMacOS = hostIsMacOS ?? Platform.isMacOS;

  final CliStoreLocator storeLocator;
  final Clock clock;
  final HttpClient Function() _newClient;

  /// The memo in front of `security find-generic-password`. Injectable so a
  /// test can count the spawns this service causes.
  final ClaudeKeychainCache _keychain;

  /// Whether this machine keeps Claude's credential in a Keychain rather than a
  /// file. Injected for the reason `CliStoreLocator.environment` is: the branch
  /// it selects has to be testable from the platform that does not have one, or
  /// it is only ever exercised on the owner's own machine.
  final bool _hostIsMacOS;

  static final _claudeUsageUrl = Uri.parse(
    'https://api.anthropic.com/api/oauth/usage',
  );
  static final _codexUsageUrl = Uri.parse(
    'https://chatgpt.com/backend-api/wham/usage',
  );
  static final _googleTokenInfoUrl = Uri.parse(
    'https://oauth2.googleapis.com/tokeninfo',
  );
  static final _googleCodeAssistUrl = Uri.parse(
    'https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist',
  );

  /// Fetches usage for [installation]. Throws [UsageException] on any failure.
  Future<AgentUsage> fetch(
    AgentInstallation installation,
    List<ExecutionEnvironment> environments,
  ) async {
    // An allowlist: only the agents whose usage endpoint we speak. Any
    // other agent — including one we have never heard of — is told plainly.
    final agentId = installation.agentId;
    if (agentId != AgentIds.claudeCode &&
        agentId != AgentIds.codex &&
        agentId != AgentIds.antigravity) {
      throw UsageException(
        'Usage is not available for '
        '${AgentRegistry.builtIn.displayNameFor(agentId)}.',
      );
    }
    final stores = await storeLocator.locate(environments);
    CliStore? store;
    for (final s in stores) {
      if (s.environmentId == installation.environmentId) {
        store = s;
        break;
      }
    }
    if (store == null) {
      throw UsageException(
        'Could not locate the store for ${describeEnvironmentId(installation.environmentId)}.',
      );
    }

    // The separator has to match the paths the store locator produced, which
    // it picks from the environment's kind. Joining with the Windows context
    // whatever the host turned `/Users/me/.codex` into `/Users/me/.codex\auth.json`
    // — a file that cannot exist — so a signed-in account reported itself
    // signed out and usage could never be read on a Mac.
    final kind = environments
        .where((e) => e.id == store!.environmentId)
        .map((e) => e.kind)
        .firstOrNull;
    final ctx = storePathContextFor(kind);
    final localMac = _hostIsMacOS && kind != null && isLocalHost(kind);

    return switch (agentId) {
      AgentIds.claudeCode => _fetchClaude(store, ctx, keychain: localMac),
      AgentIds.codex => _fetchCodex(store, ctx),
      AgentIds.antigravity => _fetchAntigravity(store, ctx),
      _ => throw UsageException(
          'Usage is not available for ${AgentRegistry.builtIn.displayNameFor(agentId)}.',
        ),
    };
  }

  Future<AgentUsage> _fetchClaude(
    CliStore store,
    p.Context ctx, {
    required bool keychain,
  }) async {
    final home = store.claudeHome;
    if (home == null) throw UsageException('No Claude store for this install.');

    // Read email from .claude.json if available
    String? email;
    final configFile = ctx.join(ctx.dirname(home), '.claude.json');
    final config = await _readJson(configFile);
    final oauthAccount = config?['oauthAccount'];
    if (oauthAccount is Map<String, dynamic>) {
      email = oauthAccount['emailAddress'] as String?;
    }

    // On macOS there is no credentials file: Claude Code keeps `claudeAiOauth`
    // in the login Keychain. Same object, different cupboard.
    if (!keychain) {
      final creds = await _readJson(ctx.join(home, '.credentials.json'));
      return _claudeUsage(_tokenIn(creds), email: email);
    }

    final read = await _keychain.read();
    // A refusal is not a signed-out user, and saying so sent people to log in
    // again over a credential that was sitting right there. macOS was asked and
    // said no — usually *Deny* on the access prompt, sometimes a locked login
    // Keychain — and only the user can undo that.
    if (read.outcome == ClaudeKeychainOutcome.refused) {
      final detail = read.detail;
      throw UsageException(
        'macOS would not release the Claude credential from the Keychain'
        '${detail == null ? '' : ' ($detail)'}. Allow Karmashala access to '
        '"${ClaudeAuthService.keychainService}" in Keychain Access.',
      );
    }
    try {
      return await _claudeUsage(_tokenIn(_decode(read.secret)), email: email);
    } on UsageException {
      // The copy being held was rejected, so it is wrong whatever the memo's
      // clock says. Dropping it here is what keeps the memo from turning a
      // refreshed token into ten minutes of "access token expired": the next
      // poll asks macOS again. The failure still stands — this fetch had no
      // good token, and saying otherwise would need a second request nobody
      // asked for.
      _keychain.forget();
      rethrow;
    }
  }

  String? _tokenIn(Map<String, dynamic>? credentials) {
    final oauth = credentials?['claudeAiOauth'];
    return oauth is Map<String, dynamic>
        ? oauth['accessToken'] as String?
        : null;
  }

  Future<AgentUsage> _claudeUsage(String? token, {String? email}) async {
    if (token == null) {
      throw UsageException('Not signed in to Claude in this environment.');
    }
    final json = await _getJson(_claudeUsageUrl, {
      'Authorization': 'Bearer $token',
      'anthropic-beta': 'oauth-2025-04-20',
    });
    return parseClaudeUsage(json, clock.nowUtc(), email: email);
  }

  Future<AgentUsage> _fetchCodex(CliStore store, p.Context ctx) async {
    final home = store.codexHome;
    if (home == null) throw UsageException('No Codex store for this install.');
    final auth = await _readJson(ctx.join(home, 'auth.json'));
    final tokens = auth?['tokens'];
    final token = tokens is Map<String, dynamic>
        ? tokens['access_token'] as String?
        : null;
    if (token == null) {
      throw UsageException('Not signed in to Codex in this environment.');
    }
    final idToken = tokens is Map<String, dynamic>
        ? tokens['id_token'] as String?
        : null;
    final emailFromJwt = _emailFromJwt(idToken);

    final json = await _getJson(_codexUsageUrl, {
      'Authorization': 'Bearer $token',
    });
    return parseCodexUsage(
      json,
      clock.nowUtc(),
      email: (json['email'] as String?) ?? emailFromJwt,
    );
  }

  Future<AgentUsage> _fetchAntigravity(CliStore store, p.Context ctx) async {
    final home = store.antigravityHome;
    if (home == null) {
      throw UsageException('No Antigravity store for this install.');
    }
    final tokenFile = ctx.join(home, 'antigravity-oauth-token');
    final auth = await _readJson(tokenFile);
    final tokenObj = auth?['token'];
    final token = tokenObj is Map<String, dynamic>
        ? tokenObj['access_token'] as String?
        : null;
    if (token == null || token.isEmpty) {
      throw UsageException('Not signed in to Antigravity in this environment.');
    }

    DateTime? tokenExpiry;
    final expiryStr = tokenObj is Map<String, dynamic>
        ? tokenObj['expiry'] as String?
        : null;
    if (expiryStr != null) {
      tokenExpiry = DateTime.tryParse(expiryStr);
      if (tokenExpiry != null && clock.nowUtc().isAfter(tokenExpiry)) {
        throw UsageException(
          'Access token expired. Run the agent once to refresh, then retry.',
        );
      }
    }

    String? email;
    try {
      final tokenInfo = await _getJson(_googleTokenInfoUrl, {
        'Authorization': 'Bearer $token',
      });
      email = tokenInfo['email'] as String?;
    } catch (_) {
      // Non-fatal if tokeninfo cannot be retrieved
    }

    final json = await _postJson(
      _googleCodeAssistUrl,
      {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      const {},
    );

    return parseAntigravityUsage(
      json,
      clock.nowUtc(),
      email: email,
      tokenExpiry: tokenExpiry,
    );
  }

  static String? _emailFromJwt(String? jwt) {
    if (jwt == null) return null;
    final parts = jwt.split('.');
    if (parts.length < 2) return null;
    try {
      var payload = parts[1];
      payload += '=' * (-payload.length % 4);
      final decoded = jsonDecode(utf8.decode(base64Url.decode(payload)));
      if (decoded is Map<String, dynamic>) {
        return decoded['email'] as String?;
      }
    } catch (_) {}
    return null;
  }

  /// Decodes a credentials blob that did not come from a file.
  Map<String, dynamic>? _decode(String? raw) {
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      // Never log `raw`: it is the credential.
      return null;
    }
  }

  Future<Map<String, dynamic>?> _readJson(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _getJson(
    Uri url,
    Map<String, String> headers,
  ) async {
    final client = _newClient();
    try {
      final request = await client.getUrl(url);
      headers.forEach(request.headers.set);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode == 401) {
        throw UsageException(
          'Access token expired. Run the agent once to refresh, then retry.',
        );
      }
      if (response.statusCode != 200) {
        throw UsageException(
          'Usage request failed (HTTP ${response.statusCode}).',
        );
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw UsageException('Unexpected usage response shape.');
      }
      return decoded;
    } on UsageException {
      rethrow;
    } catch (e) {
      throw UsageException('Could not reach the usage service: $e');
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _postJson(
    Uri url,
    Map<String, String> headers,
    Object body,
  ) async {
    final client = _newClient();
    try {
      final request = await client.postUrl(url);
      headers.forEach(request.headers.set);
      request.write(jsonEncode(body));
      final response = await request.close();
      final resBody = await response.transform(utf8.decoder).join();
      if (response.statusCode == 401) {
        throw UsageException(
          'Access token expired. Run the agent once to refresh, then retry.',
        );
      }
      if (response.statusCode != 200) {
        throw UsageException(
          'Usage request failed (HTTP ${response.statusCode}).',
        );
      }
      final decoded = jsonDecode(resBody);
      if (decoded is! Map<String, dynamic>) {
        throw UsageException('Unexpected usage response shape.');
      }
      return decoded;
    } on UsageException {
      rethrow;
    } catch (e) {
      throw UsageException('Could not reach the usage service: $e');
    } finally {
      client.close(force: true);
    }
  }
}

// --- Pure parsers (testable without any IO) ---------------------------------

/// Parses Claude Code's `/api/oauth/usage` response into every quota it reports:
/// the named 5-hour / 7-day / Opus / Sonnet windows, the per-model weekly limits
/// in `limits[]` (e.g. a model-scoped weekly cap), and paid `extra_usage` when
/// enabled. The `session` entry in `limits[]` mirrors `five_hour`, so it is
/// dropped to avoid a duplicate row.
AgentUsage parseClaudeUsage(
  Map<String, dynamic> json,
  DateTime now, {
  String? email,
}) {
  final windows = <UsageWindow>[];

  void addNamed(String key, String label) {
    final w = json[key];
    if (w is Map<String, dynamic> && w['utilization'] is num) {
      windows.add(
        UsageWindow(
          label: label,
          percent: (w['utilization'] as num).toDouble(),
          resetsAt: _parseIsoDate(w['resets_at']),
        ),
      );
    }
  }

  addNamed('five_hour', '5-hour');
  addNamed('seven_day', '7-day');
  addNamed('seven_day_opus', 'Opus · 7-day');
  addNamed('seven_day_sonnet', 'Sonnet · 7-day');

  // Per-model / scoped limits. Only model-scoped entries are added here; the
  // generic session/weekly buckets are already covered by the named keys above.
  final limits = json['limits'];
  if (limits is List) {
    for (final entry in limits) {
      if (entry is! Map<String, dynamic> || entry['percent'] is! num) continue;
      final scope = entry['scope'];
      final model = scope is Map<String, dynamic> && scope['model'] is Map
          ? (scope['model'] as Map)['display_name'] as String?
          : null;
      if (model == null) continue;
      final group = entry['group'];
      final period = group == 'weekly' ? 'weekly' : (group as String? ?? '');
      windows.add(
        UsageWindow(
          label: period.isEmpty ? model : '$model · $period',
          percent: (entry['percent'] as num).toDouble(),
          resetsAt: _parseIsoDate(entry['resets_at']),
        ),
      );
    }
  }

  // Paid overage, only when the account has it enabled.
  final extra = json['extra_usage'];
  if (extra is Map<String, dynamic> &&
      extra['is_enabled'] == true &&
      extra['utilization'] is num) {
    windows.add(
      UsageWindow(
        label: 'Extra usage',
        percent: (extra['utilization'] as num).toDouble(),
      ),
    );
  }

  return AgentUsage(windows: windows, fetchedAt: now, email: email);
}

/// Parses Codex's `/backend-api/wham/usage` response. The two rate-limit
/// windows become 5-hour / 7-day [UsageWindow]s.
AgentUsage parseCodexUsage(
  Map<String, dynamic> json,
  DateTime now, {
  String? email,
}) {
  final windows = <UsageWindow>[];
  final rateLimit = json['rate_limit'];
  if (rateLimit is Map<String, dynamic>) {
    void add(String key, String label) {
      final w = rateLimit[key];
      if (w is Map<String, dynamic> && w['used_percent'] is num) {
        windows.add(
          UsageWindow(
            label: label,
            percent: (w['used_percent'] as num).toDouble(),
            resetsAt: _codexReset(w, now),
          ),
        );
      }
    }

    add('primary_window', '5-hour');
    add('secondary_window', '7-day');
  }
  return AgentUsage(
    windows: windows,
    fetchedAt: now,
    email: email ?? (json['email'] as String?),
  );
}

/// Parses Antigravity / Gemini Code Assist's `loadCodeAssist` response.
AgentUsage parseAntigravityUsage(
  Map<String, dynamic> json,
  DateTime now, {
  String? email,
  DateTime? tokenExpiry,
}) {
  final windows = <UsageWindow>[];
  final tiers = json['allowedTiers'];
  if (tiers is List && tiers.isNotEmpty) {
    for (final tier in tiers) {
      if (tier is Map<String, dynamic>) {
        final name = tier['name'] as String? ?? 'Gemini Code Assist';
        windows.add(
          UsageWindow(
            label: name,
            percent: 0.0,
            resetsAt: tokenExpiry,
          ),
        );
      }
    }
  } else {
    windows.add(
      UsageWindow(
        label: 'Gemini Code Assist',
        percent: 0.0,
        resetsAt: tokenExpiry,
      ),
    );
  }
  return AgentUsage(
    windows: windows,
    fetchedAt: now,
    email: email,
  );
}

DateTime? _parseIsoDate(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value);
}

DateTime? _codexReset(Map<String, dynamic> window, DateTime now) {
  final resetAt = window['reset_at'];
  if (resetAt is num) {
    return DateTime.fromMillisecondsSinceEpoch(resetAt.toInt() * 1000);
  }
  final after = window['reset_after_seconds'];
  if (after is num) return now.add(Duration(seconds: after.toInt()));
  return null;
}
