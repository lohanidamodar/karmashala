import '../adapter/agent_usage_endpoint.dart';
import '../data/usage_credentials.dart';
import '../data/usage_exception.dart';
import '../data/usage_throttle.dart'
    show kUsageFiveHourWindow, kUsageSevenDayWindow;
import '../domain/agent_usage.dart';

/// Antigravity's usage, authorised with the OAuth token `agy` keeps in its
/// store: the quota buckets `retrieveUserQuotaSummary` / `retrieveUserQuota`
/// report ([parseAntigravityQuota]), and only when neither answers the tiers
/// `loadCodeAssist` names, which measure nothing ([parseAntigravityUsage]).
class AntigravityUsageEndpoint implements AgentUsageEndpoint {
  const AntigravityUsageEndpoint();

  static final _tokenInfoUrl = Uri.parse(
    'https://oauth2.googleapis.com/tokeninfo',
  );
  static final _codeAssistUrl = Uri.parse(
    'https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist',
  );

  @override
  Future<AgentUsage> read(UsageReadContext context) async {
    final home = context.storeHome;
    if (home == null) {
      throw UsageException('No Antigravity store for this install.');
    }
    final tokenFile = context.paths.join(home, 'antigravity-oauth-token');
    final auth = await readUsageCredential(tokenFile);
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
      if (tokenExpiry != null && context.clock.nowUtc().isAfter(tokenExpiry)) {
        throw UsageException(
          'Access token expired. Run the agent once to refresh, then retry.',
        );
      }
    }

    String? email =
        emailFromJwt(auth?['id_token'] as String?) ??
        emailFromJwt(
          tokenObj is Map<String, dynamic>
              ? tokenObj['id_token'] as String?
              : null,
        );
    if (email == null) {
      try {
        final tokenInfo = await context.http.getJson(_tokenInfoUrl, {
          'Authorization': 'Bearer $token',
        });
        email = tokenInfo['email'] as String?;
      } catch (_) {
        // Non-fatal if tokeninfo cannot be retrieved
      }
    }

    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
    final now = context.clock.nowUtc();

    // The quota itself, as `agy` and the Antigravity app read it: the summary
    // (5-hour and weekly buckets) and then the per-model buckets, each from
    // the daily host first — the production one pins every meter at 100%.
    for (final url in _quotaUrls) {
      try {
        final json = await context.http.postJson(url, headers, const {});
        final usage = parseAntigravityQuota(
          json,
          now,
          email: email,
          tokenExpiry: tokenExpiry,
        );
        if (usage != null) return usage;
      } on UsageException {
        // Any refusal moves on to the next source: the tier read below is the
        // one that has always answered, and a refused sign-in is said there.
      }
    }

    // Last: the tiers the account may use, which name a plan and count nothing.
    final json = await context.http.postJson(_codeAssistUrl, headers, const {});
    return parseAntigravityUsage(
      json,
      now,
      email: email,
      tokenExpiry: tokenExpiry,
    );
  }

  static final _quotaUrls = [
    for (final method in ['retrieveUserQuotaSummary', 'retrieveUserQuota'])
      for (final host in [
        'daily-cloudcode-pa.googleapis.com',
        'cloudcode-pa.googleapis.com',
      ])
        Uri.parse('https://$host/v1internal:$method'),
  ];
}

/// **Antigravity's quota**, from either reply the service gives: the summary's
/// `groups[].buckets[]` (named windows — `Gemini Session`, `Gemini Weekly`,
/// `Claude + GPT Session` …) or `retrieveUserQuota`'s per-model `buckets[]`.
/// A bucket reports what is *left*; a window says what is *used*. Null when
/// the reply holds no bucket at all, so the caller asks the next source.
AgentUsage? parseAntigravityQuota(
  Map<String, dynamic> json,
  DateTime now, {
  String? email,
  DateTime? tokenExpiry,
}) {
  final windows = <UsageWindow>[];
  final summary = json['response'] is Map<String, dynamic>
      ? json['response'] as Map<String, dynamic>
      : json;
  final groups = summary['groups'];
  if (groups is List) {
    for (final group in groups.whereType<Map<String, dynamic>>()) {
      final buckets = group['buckets'];
      if (buckets is! List) continue;
      for (final bucket in buckets.whereType<Map<String, dynamic>>()) {
        final remaining = bucket['remaining'];
        final label =
            bucket['displayName'] as String? ??
            bucket['bucketId'] as String? ??
            group['displayName'] as String? ??
            _antigravityTier;
        windows.add(
          _quotaWindow(
            label,
            remaining is Map<String, dynamic>
                ? remaining['remainingFraction']
                : bucket['remainingFraction'],
            bucket['resetTime'] ??
                (remaining is Map<String, dynamic>
                    ? remaining['resetTime']
                    : null),
            span: _spanOf(label),
          ),
        );
      }
    }
  }
  final buckets = json['buckets'];
  if (windows.isEmpty && buckets is List) {
    for (final bucket in buckets.whereType<Map<String, dynamic>>()) {
      windows.add(
        _quotaWindow(
          bucket['modelId'] as String? ?? _antigravityTier,
          bucket['remainingFraction'],
          bucket['resetTime'],
        ),
      );
    }
  }
  if (windows.isEmpty) return null;
  return AgentUsage(
    windows: windows,
    fetchedAt: now,
    email: email,
    tokenExpiresAt: tokenExpiry,
  );
}

UsageWindow _quotaWindow(
  String label,
  Object? remainingFraction,
  Object? resetTime, {
  Duration? span,
}) {
  final left = remainingFraction is num ? remainingFraction.toDouble() : null;
  return UsageWindow(
    label: label,
    percent: left == null ? null : ((1 - left) * 100).clamp(0, 100).toDouble(),
    resetsAt: resetTime is String
        ? DateTime.tryParse(resetTime)?.toUtc()
        : null,
    span: span,
  );
}

/// A bucket's period, read off its name: a session is the 5-hour window, a
/// week the 7-day one. Anything else is a model-scoped limit with no period.
Duration? _spanOf(String label) {
  final name = label.toLowerCase();
  if (name.contains('session') || name.contains('5-hour')) {
    return kUsageFiveHourWindow;
  }
  if (name.contains('week')) return kUsageSevenDayWindow;
  return null;
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
