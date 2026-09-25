import '../../util/json_file.dart';
import '../adapter/agent_usage_endpoint.dart';
import '../data/usage_credentials.dart';
import '../data/usage_exception.dart';
import '../data/usage_throttle.dart';
import '../domain/agent_usage.dart';
import '../domain/usage_failure.dart';
import 'claude_auth_service.dart';

/// Claude Code's usage: `GET https://api.anthropic.com/api/oauth/usage` with
/// the `claudeAiOauth.accessToken` from `.claude/.credentials.json` — or, on a
/// Mac, from the login Keychain.
///
/// Tokens are only read (never written) and never logged. If the stored access
/// token has expired the request 401s; rather than refresh it ourselves (which
/// could disturb the CLI's own credentials), the user is told to run the agent
/// once to refresh.
class ClaudeUsageEndpoint implements AgentUsageEndpoint {
  const ClaudeUsageEndpoint();

  static final _url = Uri.parse('https://api.anthropic.com/api/oauth/usage');

  @override
  Future<AgentUsage> read(UsageReadContext context) async {
    final home = context.storeHome;
    if (home == null) {
      throw UsageException(
        'No Claude store for this install.',
        kind: UsageFailureKind.notAsked,
      );
    }
    final ctx = context.paths;

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
    if (!context.localMacHost) {
      final creds = await readUsageCredential(
        ctx.join(home, '.credentials.json'),
      );
      return _usage(context, _tokenIn(creds), email: email);
    }

    final read = await context.keychain.read();
    // A refusal is not a signed-out user, and saying so sent people to log in
    // again over a credential that was sitting right there. macOS was asked and
    // said no — usually *Deny* on the access prompt, sometimes a locked login
    // Keychain — and only the user can undo that.
    if (read.outcome == ClaudeKeychainOutcome.refused) {
      // One wording for both surfaces, age included: the memo holds a refusal
      // for ten minutes, so what the chip shows can be ten minutes old and
      // must say so.
      throw UsageException(
        claudeKeychainRefusalMessage(read, now: context.clock.nowUtc()),
        kind: UsageFailureKind.auth,
      );
    }
    try {
      return await _usage(
        context,
        _tokenIn(decodeUsageCredential(read.secret)),
        email: email,
      );
    } on UsageException {
      // The copy being held was rejected, so it is wrong whatever the memo's
      // clock says. Dropping it here is what keeps the memo from turning a
      // refreshed token into ten minutes of "access token expired": the next
      // poll asks macOS again. The failure still stands — this fetch had no
      // good token, and saying otherwise would need a second request nobody
      // asked for.
      context.keychain.forget();
      rethrow;
    }
  }

  String? _tokenIn(Map<String, dynamic>? credentials) {
    final oauth = credentials?['claudeAiOauth'];
    return oauth is Map<String, dynamic>
        ? oauth['accessToken'] as String?
        : null;
  }

  Future<AgentUsage> _usage(
    UsageReadContext context,
    String? token, {
    String? email,
  }) async {
    if (token == null) {
      throw UsageException(
        'Not signed in to Claude in this environment.',
        kind: UsageFailureKind.auth,
      );
    }
    final json = await context.http.getJson(_url, {
      'Authorization': 'Bearer $token',
      'anthropic-beta': 'oauth-2025-04-20',
    });
    return parseClaudeUsage(json, context.clock.nowUtc(), email: email);
  }
}

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

DateTime? _parseIsoDate(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value);
}
