import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../util/clock.dart';
import '../../util/json_file.dart';
import '../../cli_detection/data/cli_store.dart';
import '../../environments/environment_kind.dart';
import '../../environments/execution_environment.dart';
import '../domain/agent_installation.dart';
import '../domain/agent_ids.dart';
import '../domain/agent_registry.dart';
import '../domain/agent_usage.dart';
import '../domain/usage_failure.dart';
import './claude_auth_service.dart';
import './usage_throttle.dart';
import '../../environments/environment_label.dart';

/// Told about a fresh reading — see [AgentUsageService.addReadingListener].
typedef UsageReadingListener =
    void Function(AgentInstallation installation, AgentUsage usage);

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
/// already has rather than asking again inside this account's floor, and it
/// refuses outright while a `429` is still in force. That is deliberate — the
/// chip, the settings panel, the fan-out dialog and the MCP tool each used to be
/// their own unrated request path, which is how a user with several panes could
/// spend far more than the poll interval suggested.
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
  static final _googleTokenInfoUrl = Uri.parse(
    'https://oauth2.googleapis.com/tokeninfo',
  );
  static final _googleCodeAssistUrl = Uri.parse(
    'https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist',
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

  /// The refusal this account would get if it asked right now, or null.
  ///
  /// So a surface can say *why* the number is not moving without making the
  /// request that would tell it — the settings panel opens on this rather than
  /// looking untroubled while the chip shows a stalled reading. Recomputed on
  /// every call, so the countdown in it is the one that is true now.
  UsageException? pendingPause(AgentInstallation installation) {
    final pause = _throttle.pauseFor(installation);
    return pause == null ? null : _waiting(pause);
  }

  /// A reading young enough to stand in for a fresh one, or null.
  ///
  /// Consulted by [fetch] itself — see there. Public because a surface may want
  /// to know whether the number it is about to show came off the wire.
  AgentUsage? rememberedIfFresh(AgentInstallation installation) =>
      _throttle.rememberedIfFresh(installation);

  /// How long a reading stands in for a fresh one, for this account.
  ///
  /// Read off the payload — [usageAskFloor] — so a five-hour quota is three
  /// minutes and a reply that named no period is one.
  Duration askFloor(AgentInstallation installation) =>
      _throttle.floorFor(installation);

  /// How long until this account is worth asking about on the app's own
  /// initiative. `UsageRefreshController` arms its tick at this.
  Duration dueIn(AgentInstallation installation) =>
      _throttle.dueIn(installation);

  /// [dueIn] by account key, for the refresh policy — which is keyed by account
  /// and therefore never holds an installation of its own.
  Duration dueInForAccount(String accountKey) =>
      _throttle.dueInForKey(accountKey);

  /// Fetches usage for [installation]. Throws [UsageException] on any failure.
  ///
  /// **Two things happen before a socket is opened**, and both are here rather
  /// than in a caller, because "every caller remembered to check" is not a
  /// property a rate limit can be defended with:
  ///
  /// * a reading inside this account's floor is handed straight back. The floor
  ///   is the shortest time in which the quota can move by a point
  ///   ([usageAskFloor]), so the request it skips could not have learned
  ///   anything. This is the one place the app's request rate is bounded — the
  ///   tick, the chip's click, a session's status moving, the Settings button,
  ///   the fan-out dialog and the MCP tool all arrive here, and four of them
  ///   used to arrive unconditionally.
  /// * a rate limit still in force refuses without asking. The whole point of a
  ///   backoff is that the request is not made.
  Future<AgentUsage> fetch(
    AgentInstallation installation,
    List<ExecutionEnvironment> environments,
  ) async {
    final fresh = _throttle.rememberedIfFresh(installation);
    if (fresh != null) return fresh;
    final pending = pendingPause(installation);
    if (pending != null) throw pending;
    try {
      final usage = await fetchFresh(installation, environments);
      _throttle.recordSuccess(installation, usage);
      _announce(installation, usage);
      return usage;
    } on UsageException catch (e) {
      if (!_worthWaitingOut(e.kind)) rethrow;
      // The server's own `Retry-After` when it sent one, our doubling when it
      // did not. Either way the wait is decided here, where the consecutive
      // count lives, and not at the socket.
      throw _waiting(
        _throttle.recordRefusal(
          installation,
          kind: e.kind,
          reason: e.message,
          retryAfter: e.retryIn,
        ),
      );
    }
  }

  final _readingListeners = <UsageReadingListener>[];

  /// Called with every reading that came off the wire — never with one served
  /// from memory inside the floor, so a history built on it records each
  /// request once and costs no request of its own.
  void addReadingListener(UsageReadingListener listener) =>
      _readingListeners.add(listener);

  void removeReadingListener(UsageReadingListener listener) =>
      _readingListeners.remove(listener);

  void _announce(AgentInstallation installation, AgentUsage usage) {
    for (final listener in [..._readingListeners]) {
      try {
        listener(installation, usage);
      } on Object {
        // A listener's failure is its own; the reading still stands.
      }
    }
  }

  /// The two failures that mean *stop asking*: being throttled, and pushing on
  /// a server that is already struggling. An expired token and an unreachable
  /// endpoint are neither — the first is fixed by the user and must be noticed
  /// on the next tick, and the second costs the vendor nothing.
  static bool _worthWaitingOut(UsageFailureKind kind) =>
      kind == UsageFailureKind.rateLimited ||
      kind == UsageFailureKind.serverBusy;

  UsageException _waiting(UsagePause pause) => UsageException(
    '${pause.reason} Waiting ${describeUsageWait(pause.wait)} before asking '
    'again.',
    kind: pause.kind,
    retryIn: pause.wait,
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
    // An allowlist: only the agents whose usage endpoint we speak. Any
    // other agent — including one we have never heard of — is told plainly.
    final agentId = installation.agentId;
    if (agentId != AgentIds.claudeCode &&
        agentId != AgentIds.codex &&
        agentId != AgentIds.antigravity) {
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
    if (home == null) {
      throw UsageException(
        'No Claude store for this install.',
        kind: UsageFailureKind.notAsked,
      );
    }

    // Read email from .claude.json if available
    String? email;
    final configFile = ctx.join(ctx.dirname(home), '.claude.json');
    // Only the email comes from here; a broken config costs the label, not the reading.
    final config = (await readJsonObjectFile(configFile)).object;
    final oauthAccount = config?['oauthAccount'];
    if (oauthAccount is Map<String, dynamic>) {
      email = oauthAccount['emailAddress'] as String?;
    }
    // On macOS there is no credentials file: Claude Code keeps `claudeAiOauth`
    // in the login Keychain. Same object, different cupboard.
    if (!keychain) {
      final creds = await _readCredential(ctx.join(home, '.credentials.json'));
      return _claudeUsage(_tokenIn(creds), email: email);
    }

    final read = await _keychain.read();
    // A refusal is not a signed-out user, and saying so sent people to log in
    // again over a credential that was sitting right there. macOS was asked and
    // said no — usually *Deny* on the access prompt, sometimes a locked login
    // Keychain — and only the user can undo that.
    if (read.outcome == ClaudeKeychainOutcome.refused) {
      // One wording for both surfaces, age included: the memo holds a refusal
      // for ten minutes, so what the chip shows can be ten minutes old and
      // must say so.
      throw UsageException(
        claudeKeychainRefusalMessage(read, now: clock.nowUtc()),
        kind: UsageFailureKind.auth,
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
      throw UsageException(
        'Not signed in to Claude in this environment.',
        kind: UsageFailureKind.auth,
      );
    }
    final json = await _getJson(_claudeUsageUrl, {
      'Authorization': 'Bearer $token',
      'anthropic-beta': 'oauth-2025-04-20',
    });
    return parseClaudeUsage(json, clock.nowUtc(), email: email);
  }

  Future<AgentUsage> _fetchCodex(CliStore store, p.Context ctx) async {
    final home = store.codexHome;
    if (home == null) {
      throw UsageException(
        'No Codex store for this install.',
        kind: UsageFailureKind.notAsked,
      );
    }
    final auth = await _readCredential(ctx.join(home, 'auth.json'));
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
    final auth = await _readCredential(tokenFile);
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

    String? email = _emailFromJwt(auth?['id_token'] as String?) ??
        _emailFromJwt(
          tokenObj is Map<String, dynamic>
              ? tokenObj['id_token'] as String?
              : null,
        );
    if (email == null) {
      try {
        final tokenInfo = await _getJson(_googleTokenInfoUrl, {
          'Authorization': 'Bearer $token',
        });
        email = tokenInfo['email'] as String?;
      } catch (_) {
        // Non-fatal if tokeninfo cannot be retrieved
      }
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

  /// The credential file's object, or null when it is absent. One that is there
  /// and unusable is said so, not reported as "not signed in".
  Future<Map<String, dynamic>?> _readCredential(String path) async {
    final read = await readJsonObjectFile(path);
    if (read.failure case final failure?) {
      throw UsageException(failure, kind: UsageFailureKind.auth);
    }
    return read.object;
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
      final retryAfter = status >= HttpStatus.tooManyRequests
          ? parseRetryAfter(
              response.headers.value(HttpHeaders.retryAfterHeader),
              clock.nowUtc(),
            )
          : null;
      final body = await response.transform(utf8.decoder).join();
      // Neither of these carries the wait itself: how long to hold off is the
      // throttle's decision, because only it knows how many refusals came
      // before this one.
      if (status == HttpStatus.tooManyRequests) {
        throw UsageException(
          'Rate limited by the usage service.',
          kind: UsageFailureKind.rateLimited,
          retryIn: retryAfter,
        );
      }
      if (status >= HttpStatus.internalServerError) {
        throw UsageException(
          'The usage service is having trouble (HTTP $status).',
          kind: UsageFailureKind.serverBusy,
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
AgentUsage parseClaudeUsage(
  Map<String, dynamic> json,
  DateTime now, {
  String? email,
}) {
  final windows = <UsageWindow>[];

  void addNamed(String key, String label, Duration span) {
    final w = json[key];
    if (w is Map<String, dynamic> && w['utilization'] is num) {
      windows.add(
        UsageWindow(
          label: label,
          percent: (w['utilization'] as num).toDouble(),
          resetsAt: _parseIsoDate(w['resets_at']),
          // The period the key itself names. Kept because it is what turns a
          // percentage into a rate — see [UsageWindow.span] and
          // [usageAskFloor].
          span: span,
        ),
      );
    }
  }

  addNamed('five_hour', '5-hour', kUsageFiveHourWindow);
  addNamed('seven_day', '7-day', kUsageSevenDayWindow);
  addNamed('seven_day_opus', 'Opus · 7-day', kUsageSevenDayWindow);
  addNamed('seven_day_sonnet', 'Sonnet · 7-day', kUsageSevenDayWindow);

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
          // Only `weekly` names a period we can read off the payload. Anything
          // else is left null rather than assumed — a window whose length we do
          // not know must not shorten the floor for the ones we do.
          span: group == 'weekly' ? kUsageSevenDayWindow : null,
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
    void add(String key, String label, Duration span) {
      final w = rateLimit[key];
      if (w is Map<String, dynamic> && w['used_percent'] is num) {
        windows.add(
          UsageWindow(
            label: label,
            percent: (w['used_percent'] as num).toDouble(),
            resetsAt: _codexReset(w, now),
            span: span,
          ),
        );
      }
    }

    add('primary_window', '5-hour', kUsageFiveHourWindow);
    add('secondary_window', '7-day', kUsageSevenDayWindow);
  }
  return AgentUsage(
    windows: windows,
    fetchedAt: now,
    email: email ?? (json['email'] as String?),
  );
}

/// Parses Antigravity / Gemini Code Assist's `loadCodeAssist` response.
///
/// **The reply carries no quota.** What it is read for is `allowedTiers`, a
/// list whose entries name the tiers the account is allowed — `id`, `name`,
/// `description`. Nothing in it counts anything: no used/limit pair, no
/// remaining, no reset. So each tier becomes a window with a label and no
/// [UsageWindow.percent], and every surface says so in words. It used to become
/// `percent: 0.0`, which is how a pane on Antigravity came to draw a confident
/// `0%` for something nothing had measured. Should the endpoint ever start
/// reporting a count, read it here — an absent percent is what "we have not
/// seen one" looks like, and it is meant to be replaced by a real reading
/// rather than by a zero.
///
/// [tokenExpiry] is the OAuth token's own `expiry`, read from the store beside
/// the access token. It is the account's, not a window's, and is reported as
/// itself — writing it into `resetsAt` had the app claiming a quota it had
/// never read would reset when the user's sign-in lapsed.
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
        windows.add(
          UsageWindow(label: tier['name'] as String? ?? _antigravityTier),
        );
      }
    }
  }
  if (windows.isEmpty) windows.add(const UsageWindow(label: _antigravityTier));
  return AgentUsage(
    windows: windows,
    fetchedAt: now,
    email: email,
    tokenExpiresAt: tokenExpiry,
  );
}

/// What a tier is called when the reply names none.
const String _antigravityTier = 'Gemini Code Assist';

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
