import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/util/clock.dart';
import '../../cli_detection/application/cli_detection_service.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/execution_environment.dart';
import '../domain/agent_installation.dart';
import '../domain/agent_ids.dart';
import '../domain/agent_registry.dart';
import '../domain/agent_usage.dart';
import '../domain/usage_failure.dart';
import 'claude_auth_service.dart';
import 'usage_throttle.dart';
import '../../environments/domain/environment_label.dart';

/// Raised when a usage lookup cannot complete.
///
/// [kind] is what the surfaces switch on: a rate limit, an expired token and an
/// unreachable endpoint are three different situations for the user, and for
/// years they arrived here as one grey dash. [message] stays the sentence a
/// human reads.
class UsageException implements Exception {
  UsageException(
    this.message, {
    this.kind = UsageFailureKind.unusable,
    this.retryIn,
  });

  final String message;

  final UsageFailureKind kind;

  /// How long until this account may ask again. Only ever set for
  /// [UsageFailureKind.rateLimited] — every other failure may be retried by the
  /// next tick.
  final Duration? retryIn;

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
///
/// **Every request the app makes to either endpoint goes through [fetch]**, and
/// [fetch] is where the [UsageThrottle] sits: it serves a reading the app
/// already has rather than asking again inside one poll interval, and it
/// refuses outright while a `429` is still in force. That is deliberate — the
/// chip, the settings panel and the fan-out dialog each used to be their own
/// unrated request path, which is how a user with several panes could spend far
/// more than the one-a-minute the poll interval suggests.
class AgentUsageService {
  AgentUsageService({
    required this.storeLocator,
    required this.clock,
    HttpClient Function()? httpClientFactory,
    ClaudeKeychainCache? keychain,
    bool? hostIsMacOS,
    UsageThrottle? throttle,
  }) : _newClient = httpClientFactory ?? HttpClient.new,
       _keychain = keychain ?? claudeKeychain,
       _hostIsMacOS = hostIsMacOS ?? Platform.isMacOS,
       _throttle = throttle ?? UsageThrottle(clock: clock);

  final CliStoreLocator storeLocator;
  final Clock clock;
  final HttpClient Function() _newClient;

  /// What was read last, and how long the vendor said to wait. Shared by every
  /// caller of this service, which is the point: one account, one limit.
  final UsageThrottle _throttle;

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

  /// The last reading taken for this account, however old, or null if none was
  /// taken in this run.
  ///
  /// **Every surface shows this when a lookup fails**, with its age beside it.
  /// A number the app read four minutes ago is worth more than a dash, as long
  /// as it never pretends to be live — the reason `AgentStatusReport.evidenceAt`
  /// exists.
  AgentUsage? remembered(AgentInstallation installation) =>
      _throttle.remembered(installation);

  /// How long this account is holding off after a `429`, or null if it may ask
  /// now. Read at render time so a countdown on screen stays true.
  Duration? rateLimitWait(AgentInstallation installation) =>
      _throttle.waitFor(installation);

  /// A reading young enough to stand in for a fresh one, or null.
  ///
  /// What stops a pane switch costing a request: `agentUsageProvider` is
  /// `autoDispose` and family-keyed on the installation, so moving between two
  /// panes re-creates it every time, and each re-creation used to be an
  /// unconditional trip to the vendor.
  AgentUsage? rememberedIfFresh(AgentInstallation installation) =>
      _throttle.rememberedIfFresh(installation);

  /// Fetches usage for [installation]. Throws [UsageException] on any failure.
  ///
  /// Refuses without a request while the account is rate limited: the whole
  /// point of a backoff is that the request is not made.
  Future<AgentUsage> fetch(
    AgentInstallation installation,
    List<ExecutionEnvironment> environments,
  ) async {
    final wait = _throttle.waitFor(installation);
    if (wait != null) throw _rateLimited(wait);
    try {
      final usage = await fetchFresh(installation, environments);
      _throttle.recordSuccess(installation, usage);
      return usage;
    } on UsageException catch (e) {
      if (e.kind != UsageFailureKind.rateLimited) rethrow;
      // The server's own `Retry-After` when it sent one, our doubling when it
      // did not. Either way the wait is decided here, where the consecutive
      // count lives, and not at the socket.
      throw _rateLimited(
        _throttle.recordRateLimit(installation, retryAfter: e.retryIn),
      );
    }
  }

  UsageException _rateLimited(Duration wait) => UsageException(
    'Rate limited by the usage service. Waiting ${describeUsageWait(wait)} '
    'before asking again.',
    kind: UsageFailureKind.rateLimited,
    retryIn: wait,
  );

  /// The lookup itself, with no memory and no backoff in front of it.
  ///
  /// Separate from [fetch] so a test double can answer the network half while
  /// still being throttled and remembered exactly like the real one.
  @protected
  @visibleForOverriding
  Future<AgentUsage> fetchFresh(
    AgentInstallation installation,
    List<ExecutionEnvironment> environments,
  ) async {
    // An allowlist: only the two agents whose usage endpoint we speak. Any
    // other agent — including one we have never heard of — is told plainly.
    final agentId = installation.agentId;
    if (agentId != AgentIds.claudeCode && agentId != AgentIds.codex) {
      throw UsageException(
        'Usage is not available for '
        '${AgentRegistry.builtIn.displayNameFor(agentId)}.',
        kind: UsageFailureKind.notAsked,
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
        kind: UsageFailureKind.notAsked,
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

    return agentId == AgentIds.claudeCode
        ? _fetchClaude(store, ctx, keychain: localMac)
        : _fetchCodex(store, ctx);
  }

  Future<AgentUsage> _fetchClaude(
    CliStore store,
    p.Context ctx, {
    required bool keychain,
  }) async {
    final home = store.claudeHome;
    if (home == null) {
      throw UsageException(
        'No Claude store for this install.',
        kind: UsageFailureKind.notAsked,
      );
    }
    // On macOS there is no credentials file: Claude Code keeps `claudeAiOauth`
    // in the login Keychain. Same object, different cupboard.
    if (!keychain) {
      final creds = await _readJson(ctx.join(home, '.credentials.json'));
      return _claudeUsage(_tokenIn(creds));
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
        kind: UsageFailureKind.auth,
      );
    }
    try {
      return await _claudeUsage(_tokenIn(_decode(read.secret)));
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

  Future<AgentUsage> _claudeUsage(String? token) async {
    if (token == null) {
      throw UsageException(
        'Not signed in to Claude in this environment.',
        kind: UsageFailureKind.auth,
      );
    }
    final json = await _getJson(_claudeUsageUrl, {
      'Authorization': 'Bearer $token',
      'anthropic-beta': 'oauth-2025-04-20',
    });
    return parseClaudeUsage(json, clock.nowUtc());
  }

  Future<AgentUsage> _fetchCodex(CliStore store, p.Context ctx) async {
    final home = store.codexHome;
    if (home == null) {
      throw UsageException(
        'No Codex store for this install.',
        kind: UsageFailureKind.notAsked,
      );
    }
    final auth = await _readJson(ctx.join(home, 'auth.json'));
    final tokens = auth?['tokens'];
    final token = tokens is Map<String, dynamic>
        ? tokens['access_token'] as String?
        : null;
    if (token == null) {
      throw UsageException(
        'Not signed in to Codex in this environment.',
        kind: UsageFailureKind.auth,
      );
    }
    final json = await _getJson(_codexUsageUrl, {
      'Authorization': 'Bearer $token',
    });
    return parseCodexUsage(json, clock.nowUtc());
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
      final status = response.statusCode;
      // Read the header before the body. On a `429` the body is a vendor error
      // blob we do not parse, and `Retry-After` — the one thing RFC 9110 says
      // every 429 may carry — is the only part of that answer worth having.
      // Both endpoints are treated identically here: neither is documented, and
      // guessing at a vendor-specific header we cannot observe without making
      // the very request we are trying not to make would be inventing evidence.
      final retryAfter = status == HttpStatus.tooManyRequests
          ? parseRetryAfter(
              response.headers.value(HttpHeaders.retryAfterHeader),
              clock.nowUtc(),
            )
          : null;
      final body = await response.transform(utf8.decoder).join();
      if (status == HttpStatus.tooManyRequests) {
        // Deliberately not a wait: how long to hold off is the throttle's
        // decision, because only it knows how many refusals came before.
        throw UsageException(
          'Usage request failed (HTTP $status).',
          kind: UsageFailureKind.rateLimited,
          retryIn: retryAfter,
        );
      }
      if (status == HttpStatus.unauthorized) {
        throw UsageException(
          'Access token expired. Run the agent once to refresh, then retry.',
          kind: UsageFailureKind.auth,
        );
      }
      if (status != HttpStatus.ok) {
        throw UsageException(
          'Usage request failed (HTTP $status).',
          kind: UsageFailureKind.unusable,
        );
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw UsageException(
          'Unexpected usage response shape.',
          kind: UsageFailureKind.unusable,
        );
      }
      return decoded;
    } on UsageException {
      rethrow;
    } on FormatException catch (e) {
      // An answer we could not read is not an endpoint we could not reach, and
      // telling the user to check their network over a malformed body sends
      // them somewhere there is nothing to find.
      throw UsageException(
        'The usage service sent something we could not read: ${e.message}',
        kind: UsageFailureKind.unusable,
      );
    } catch (e) {
      throw UsageException(
        'Could not reach the usage service: $e',
        kind: UsageFailureKind.unreachable,
      );
    } finally {
      client.close(force: true);
    }
  }
}

/// `Retry-After`, in either form RFC 9110 allows: a delay in seconds, or an
/// HTTP-date to wait until.
///
/// Null when the header is absent or unreadable — the caller then falls back to
/// its own doubling, which is the case that has to work anyway, since neither
/// vendor promises the header.
Duration? parseRetryAfter(String? header, DateTime now) {
  final raw = header?.trim();
  if (raw == null || raw.isEmpty) return null;
  final seconds = int.tryParse(raw);
  if (seconds != null) {
    return seconds <= 0 ? Duration.zero : Duration(seconds: seconds);
  }
  try {
    final until = HttpDate.parse(raw);
    final wait = until.difference(now);
    return wait.isNegative ? Duration.zero : wait;
  } on Exception {
    return null;
  }
}

// --- Pure parsers (testable without any IO) ---------------------------------

/// Parses Claude Code's `/api/oauth/usage` response into every quota it reports:
/// the named 5-hour / 7-day / Opus / Sonnet windows, the per-model weekly limits
/// in `limits[]` (e.g. a model-scoped weekly cap), and paid `extra_usage` when
/// enabled. The `session` entry in `limits[]` mirrors `five_hour`, so it is
/// dropped to avoid a duplicate row.
AgentUsage parseClaudeUsage(Map<String, dynamic> json, DateTime now) {
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

  return AgentUsage(windows: windows, fetchedAt: now);
}

/// Parses Codex's `/backend-api/wham/usage` response. The two rate-limit
/// windows become 5-hour / 7-day [UsageWindow]s.
AgentUsage parseCodexUsage(Map<String, dynamic> json, DateTime now) {
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
    email: json['email'] as String?,
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
