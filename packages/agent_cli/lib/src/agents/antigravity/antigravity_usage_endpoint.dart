import '../adapter/agent_usage_endpoint.dart';
import '../data/usage_credentials.dart';
import '../data/usage_exception.dart';
import '../data/usage_throttle.dart'
    show kUsageFiveHourWindow, kUsageSevenDayWindow;
import '../domain/agent_usage.dart';
import '../domain/usage_failure.dart';

/// Antigravity's usage, authorised with the OAuth credential `agy`
/// (`antigravity-oauth-token`) or `agy_acp_server` (`acp_token.json`) keeps in
/// its store: the quota buckets `retrieveUserQuotaSummary` reports
/// ([parseAntigravityQuota]), supplemented with `retrieveUserQuota`
/// ([parseAntigravityModelQuota]) when the summary omits Gemini's quota group.
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
  static final _defaultTokenUrl = Uri.parse(
    'https://oauth2.googleapis.com/token',
  );

  static const _hosts = [
    'daily-cloudcode-pa.googleapis.com',
    'cloudcode-pa.googleapis.com',
  ];

  @override
  Future<AgentUsage> read(UsageReadContext context) async {
    final home = context.storeHome;
    if (home == null) {
      throw UsageException(
        'No Antigravity store for this install.',
        kind: UsageFailureKind.notAsked,
      );
    }

    var auth = await _resolveToken(context, home, allowCliRefresh: true);
    try {
      return await _fetchQuota(context, auth);
    } on UsageException catch (e) {
      // A token that appeared unexpired on disk can still be rejected with 401
      // (clock skew or revocation); give `agy` one chance to refresh it.
      if (e.kind == UsageFailureKind.auth &&
          auth.fromCliToken &&
          await _refreshViaCli(context)) {
        auth = await _resolveToken(context, home, allowCliRefresh: false);
        return _fetchQuota(context, auth);
      }
      rethrow;
    }
  }

  /// Resolves a usable Bearer token from [home] (trying `antigravity-oauth-token`
  /// then `acp_token.json`, then the sibling Antigravity store under `.gemini`).
  Future<_AntigravityAuth> _resolveToken(
    UsageReadContext context,
    String home, {
    required bool allowCliRefresh,
  }) async {
    final paths = context.paths;
    final parent = paths.dirname(home);
    final candidates = <({String path, bool isAcp})>[
      (path: paths.join(home, 'antigravity-oauth-token'), isAcp: false),
      (path: paths.join(home, 'acp_token.json'), isAcp: true),
      if (parent != home) ...[
        (
          path: paths.join(parent, 'antigravity-cli', 'antigravity-oauth-token'),
          isAcp: false,
        ),
        (
          path: paths.join(parent, 'antigravity-acp', 'acp_token.json'),
          isAcp: true,
        ),
      ],
    ];

    final seen = <String>{};
    UsageException? expiredCli;
    for (final candidate in candidates) {
      if (!seen.add(candidate.path)) continue;
      final blob = await readUsageCredential(candidate.path, io: context.io);
      if (blob == null) continue;
      if (!candidate.isAcp) {
        final read = await _readCliToken(
          context,
          candidate.path,
          blob,
          allowCliRefresh: allowCliRefresh,
        );
        if (read.auth != null) return read.auth!;
        expiredCli ??= read.expired;
      } else {
        final acp = await _exchangeAcpToken(context, blob);
        if (acp != null) return acp;
      }
    }
    if (expiredCli != null) throw expiredCli;
    throw UsageException(
      'Not signed in to Antigravity in this environment.',
      kind: UsageFailureKind.auth,
    );
  }

  Future<({_AntigravityAuth? auth, UsageException? expired})> _readCliToken(
    UsageReadContext context,
    String tokenFile,
    Map<String, dynamic> initialBlob, {
    required bool allowCliRefresh,
  }) async {
    Map<String, dynamic>? blob = initialBlob;
    for (var attempt = 0; attempt < 2; attempt++) {
      final tokenObj = blob?['token'];
      final token = tokenObj is Map<String, dynamic>
          ? tokenObj['access_token'] as String?
          : null;
      if (token == null || token.isEmpty) return (auth: null, expired: null);

      DateTime? tokenExpiry;
      final expiryStr = tokenObj is Map<String, dynamic>
          ? tokenObj['expiry'] as String?
          : null;
      if (expiryStr != null) tokenExpiry = DateTime.tryParse(expiryStr);

      final isExpired =
          tokenExpiry != null && context.clock.nowUtc().isAfter(tokenExpiry);
      if (isExpired) {
        if (attempt == 0 && allowCliRefresh && await _refreshViaCli(context)) {
          blob = await readUsageCredential(tokenFile, io: context.io);
          continue;
        }
        return (
          auth: null,
          expired: UsageException(
            'Access token expired. Run the agent once to refresh, then retry.',
            kind: UsageFailureKind.auth,
          ),
        );
      }

      final idEmail = blob?['id_token_email'] as String?;
      final email = (idEmail != null && idEmail.isNotEmpty)
          ? idEmail
          : emailFromJwt(blob?['id_token'] as String?) ??
                emailFromJwt(
                  tokenObj is Map<String, dynamic>
                      ? tokenObj['id_token'] as String?
                      : null,
                );
      return (
        auth: _AntigravityAuth(
          accessToken: token,
          email: email,
          tokenExpiry: tokenExpiry,
          fromCliToken: true,
        ),
        expired: null,
      );
    }
    return (auth: null, expired: null);
  }

  /// Exchanges an `acp_token.json` refresh token in-memory for a short-lived
  /// access token without writing anything to disk.
  Future<_AntigravityAuth?> _exchangeAcpToken(
    UsageReadContext context,
    Map<String, dynamic> blob,
  ) async {
    final refreshToken = blob['refresh_token'] as String?;
    final clientId = blob['client_id'] as String?;
    final clientSecret = blob['client_secret'] as String?;
    if (refreshToken == null ||
        refreshToken.isEmpty ||
        clientId == null ||
        clientId.isEmpty ||
        clientSecret == null ||
        clientSecret.isEmpty) {
      return null;
    }
    final tokenUriStr = blob['token_uri'] as String?;
    final tokenUri = (tokenUriStr != null && tokenUriStr.isNotEmpty)
        ? (Uri.tryParse(tokenUriStr) ?? _defaultTokenUrl)
        : _defaultTokenUrl;
    final Map<String, dynamic> reply;
    try {
      reply = await context.http.postFormJson(tokenUri, {
        'grant_type': 'refresh_token',
        'client_id': clientId,
        'client_secret': clientSecret,
        'refresh_token': refreshToken,
      });
    } on UsageException catch (e) {
      // OAuth2 returns HTTP 400 (invalid_grant) when a refresh token was
      // revoked or expired; surface that as an auth failure.
      if (e.kind == UsageFailureKind.unusable) {
        throw UsageException(
          'Antigravity sign-in expired. Sign in again, then retry.',
          kind: UsageFailureKind.auth,
        );
      }
      rethrow;
    }
    final accessToken = reply['access_token'] as String?;
    if (accessToken == null || accessToken.isEmpty) {
      throw UsageException(
        'Antigravity sign-in refresh returned no access token.',
        kind: UsageFailureKind.auth,
      );
    }
    final expiresIn = reply['expires_in'];
    final tokenExpiry = expiresIn is num && expiresIn > 0
        ? context.clock.nowUtc().add(Duration(seconds: expiresIn.round()))
        : null;
    final email = emailFromJwt(reply['id_token'] as String?);
    return _AntigravityAuth(
      accessToken: accessToken,
      email: email,
      tokenExpiry: tokenExpiry,
      fromCliToken: false,
    );
  }

  /// Invokes `agy models` once so the CLI refreshes its own OAuth token file.
  /// Only runs when the installation's executable is `agy` (never
  /// `agy_acp_server`, which does not have a `models` subcommand).
  Future<bool> _refreshViaCli(UsageReadContext context) async {
    final run = context.runExecutable;
    if (run == null) return false;
    final exe = context.executablePath;
    if (exe != null && !_isAgyCliExecutable(exe)) return false;
    return run(const ['models']);
  }

  static bool _isAgyCliExecutable(String path) {
    final base = path.split(RegExp(r'[/\\]')).last.toLowerCase();
    return base == 'agy' || base == 'agy.exe';
  }

  Future<AgentUsage> _fetchQuota(
    UsageReadContext context,
    _AntigravityAuth auth,
  ) async {
    var email = auth.email;
    if (email == null) {
      try {
        final tokenInfo = await context.http.getJson(_tokenInfoUrl, {
          'Authorization': 'Bearer ${auth.accessToken}',
        });
        email = tokenInfo['email'] as String?;
      } catch (_) {
        // Non-fatal if tokeninfo cannot be retrieved.
      }
    }

    final headers = {
      'Authorization': 'Bearer ${auth.accessToken}',
      'Content-Type': 'application/json',
      ...kAntigravityClientHeaders,
    };
    final now = context.clock.nowUtc();

    // The daily host first, as the Antigravity app asks; the production one
    // answers the same summary when the daily one does not.
    UsageException? refused;
    for (final host in _hosts) {
      final summaryUrl = Uri.parse(
        'https://$host/v1internal:retrieveUserQuotaSummary',
      );
      try {
        final summaryJson = await context.http.postJson(
          summaryUrl,
          headers,
          const {},
        );
        final summary = parseAntigravityQuota(
          summaryJson,
          now,
          email: email,
          tokenExpiry: auth.tokenExpiry,
        );
        final summaryWindows = summary?.windows ?? const <UsageWindow>[];
        final hasGemini = summaryWindows.any(
          (w) => w.label.toLowerCase().startsWith('gemini'),
        );
        if (summary != null && hasGemini) return summary;

        // Current accounts often receive only third-party (Claude + GPT) groups
        // from retrieveUserQuotaSummary; fetch per-model buckets to include
        // Gemini's live quota window.
        List<UsageWindow> supplemented = const [];
        try {
          final bucketsUrl = Uri.parse(
            'https://$host/v1internal:retrieveUserQuota',
          );
          final bucketsJson = await context.http.postJson(
            bucketsUrl,
            headers,
            const {},
          );
          supplemented = parseAntigravityModelQuota(
            bucketsJson,
            includeThirdParty: summaryWindows.isEmpty,
          );
        } on UsageException {
          // Keep whatever summary windows succeeded if per-model lookup failed.
        }

        final combined = [...supplemented, ...summaryWindows];
        if (combined.isNotEmpty) {
          return AgentUsage(
            windows: combined,
            fetchedAt: now,
            email: email,
            tokenExpiresAt: auth.tokenExpiry,
          );
        }
        refused = UsageException(
          'Antigravity reported no quota buckets.',
          kind: UsageFailureKind.unusable,
        );
      } on UsageException catch (e) {
        refused = e;
      }
    }
    throw refused!;
  }
}

class _AntigravityAuth {
  const _AntigravityAuth({
    required this.accessToken,
    required this.email,
    required this.tokenExpiry,
    required this.fromCliToken,
  });

  final String accessToken;
  final String? email;
  final DateTime? tokenExpiry;
  final bool fromCliToken;
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

/// **Per-model quota buckets**, from `retrieveUserQuota`: folds `gemini-*`
/// buckets that carry a `resetTime` (excluding `tab_*` autocomplete buckets)
/// into one `Gemini · 5-hour` window using the lowest `remainingFraction`
/// (tightest model quota). When [includeThirdParty] is true, folds `claude-*`
/// and `gpt-*` buckets into `Claude + GPT · 5-hour` as well.
List<UsageWindow> parseAntigravityModelQuota(
  Map<String, dynamic> json, {
  bool includeThirdParty = false,
}) {
  final payload = json['response'] is Map<String, dynamic>
      ? json['response'] as Map<String, dynamic>
      : json;
  final buckets = payload['buckets'];
  if (buckets is! List) return const [];

  UsageWindow? foldGroup(String label, bool Function(String modelId) matches) {
    double? lowestRemaining;
    DateTime? resetAt;
    for (final bucket in buckets.whereType<Map<String, dynamic>>()) {
      final modelId = (bucket['modelId'] as String? ?? '').toLowerCase();
      if (modelId.isEmpty || modelId.startsWith('tab_') || !matches(modelId)) {
        continue;
      }
      final left = bucket['remainingFraction'];
      final resetStr = bucket['resetTime'] as String?;
      final parsedReset = resetStr == null
          ? null
          : DateTime.tryParse(resetStr)?.toUtc();
      if (left is! num || parsedReset == null) continue;
      final remaining = left.toDouble().clamp(0.0, 1.0);
      if (lowestRemaining == null ||
          remaining < lowestRemaining ||
          (remaining == lowestRemaining &&
              (resetAt == null || parsedReset.isBefore(resetAt)))) {
        lowestRemaining = remaining;
        resetAt = parsedReset;
      }
    }
    if (lowestRemaining == null) return null;
    return UsageWindow(
      label: label,
      percent: ((1 - lowestRemaining) * 100).clamp(0, 100).toDouble(),
      resetsAt: resetAt,
      span: kUsageFiveHourWindow,
    );
  }

  final gemini = foldGroup(
    'Gemini · 5-hour',
    (id) => id.startsWith('gemini-'),
  );
  final thirdParty = includeThirdParty
      ? foldGroup(
          'Claude + GPT · 5-hour',
          (id) => id.startsWith('claude-') || id.startsWith('gpt-'),
        )
      : null;
  return [?gemini, ?thirdParty];
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
