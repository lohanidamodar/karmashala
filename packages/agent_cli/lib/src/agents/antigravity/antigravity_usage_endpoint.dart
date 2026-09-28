import '../adapter/agent_usage_endpoint.dart';
import '../data/usage_credentials.dart';
import '../data/usage_exception.dart';
import '../data/usage_throttle.dart'
    show kUsageFiveHourWindow, kUsageSevenDayWindow;
import '../domain/agent_usage.dart';

/// Antigravity's usage, authorised with the OAuth token `agy` keeps in its
/// store: the quota buckets `retrieveUserQuotaSummary` reports
/// ([parseAntigravityQuota]).
///
/// The service answers only a caller that says it is the Antigravity IDE
/// ([kAntigravityClientHeaders]). Without that it refuses the quota with
/// `SUBSCRIPTION_REQUIRED`, and the only thing left to read is the tier list
/// `loadCodeAssist` gives, which names "Gemini Code Assist" and counts
/// nothing. A refusal is reported as one, never as that tier.
class AntigravityUsageEndpoint implements AgentUsageEndpoint {
  const AntigravityUsageEndpoint();

  static final _tokenInfoUrl = Uri.parse(
    'https://oauth2.googleapis.com/tokeninfo',
  );

  @override
  Future<AgentUsage> read(UsageReadContext context) async {
    final home = context.storeHome;
    if (home == null) {
      throw UsageException('No Antigravity store for this install.');
    }
    final tokenFile = context.paths.join(home, 'antigravity-oauth-token');
    final auth = await readUsageCredential(tokenFile, io: context.io);
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
      ...kAntigravityClientHeaders,
    };
    final now = context.clock.nowUtc();

    // The daily host first, as the Antigravity app asks; the production one
    // answers the same summary when the daily one does not.
    UsageException? refused;
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
        refused = UsageException('Antigravity reported no quota buckets.');
      } on UsageException catch (e) {
        refused = e;
      }
    }
    throw refused!;
  }

  static final _quotaUrls = [
    for (final host in [
      'daily-cloudcode-pa.googleapis.com',
      'cloudcode-pa.googleapis.com',
    ])
      Uri.parse('https://$host/v1internal:retrieveUserQuotaSummary'),
  ];
}

/// What the Antigravity IDE says of itself on every Cloud Code call. The
/// quota endpoints answer only a caller that sends it.
const Map<String, String> kAntigravityClientHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Antigravity/1.0.0 Chrome/138.0.7204.235 '
      'Electron/37.3.1 Safari/537.36',
  'X-Goog-Api-Client': 'google-cloud-sdk vscode_cloudshelleditor/0.1',
  'Client-Metadata':
      '{"ideType":"ANTIGRAVITY","platform":"WINDOWS","pluginType":"GEMINI"}',
};

/// **Antigravity's quota**, from `retrieveUserQuotaSummary`: model groups
/// (`Gemini Models`, `Claude and GPT models`), each with a `5h` and a
/// `weekly` bucket. A bucket reports what is *left*; a window says what is
/// *used*. Each window is named for its group and its period — every bucket
/// is called "… Limit Remaining", so the bucket's own name tells none apart.
/// Null when the reply holds no bucket at all.
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
      final groupName = _groupName(group['displayName'] as String?);
      for (final bucket in buckets.whereType<Map<String, dynamic>>()) {
        final span = _spanOf(bucket);
        final period = switch (span) {
          kUsageFiveHourWindow => '5-hour',
          kUsageSevenDayWindow => 'weekly',
          _ =>
            bucket['window'] as String? ??
                bucket['displayName'] as String? ??
                bucket['bucketId'] as String?,
        };
        final left = bucket['remainingFraction'];
        final reset = bucket['resetTime'];
        windows.add(
          UsageWindow(
            label: [groupName, period].whereType<String>().join(' · '),
            percent: left is num
                ? ((1 - left.toDouble()) * 100).clamp(0, 100).toDouble()
                : null,
            resetsAt: reset is String
                ? DateTime.tryParse(reset)?.toUtc()
                : null,
            span: span,
          ),
        );
      }
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

/// A group's name without the words that only pad it: `Gemini Models` is
/// Gemini, `Claude and GPT models` is Claude + GPT.
String? _groupName(String? name) {
  if (name == null) return null;
  final short = name
      .replaceAll(RegExp(r'\s+models?$', caseSensitive: false), '')
      .replaceAll(' and ', ' + ')
      .trim();
  return short.isEmpty ? name : short;
}

/// A bucket's period, as its `window` names it (`5h`, `weekly`), else read
/// off its id or name. Anything else has no period we know.
Duration? _spanOf(Map<String, dynamic> bucket) {
  final said = [
    bucket['window'],
    bucket['bucketId'],
    bucket['displayName'],
  ].whereType<String>().join(' ').toLowerCase();
  if (said.contains('5h') ||
      said.contains('five hour') ||
      said.contains('5-hour') ||
      said.contains('session')) {
    return kUsageFiveHourWindow;
  }
  if (said.contains('week')) return kUsageSevenDayWindow;
  return null;
}
