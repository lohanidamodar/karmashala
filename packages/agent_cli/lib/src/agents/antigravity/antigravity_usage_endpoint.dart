import '../adapter/agent_usage_endpoint.dart';
import '../data/usage_credentials.dart';
import '../data/usage_exception.dart';
import '../domain/agent_usage.dart';

/// Antigravity's usage: Gemini Code Assist's `loadCodeAssist`, authorised with
/// the OAuth token `agy` keeps in its store. Names tiers, measures nothing —
/// see [parseAntigravityUsage].
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

    final json = await context.http.postJson(_codeAssistUrl, {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    }, const {});

    return parseAntigravityUsage(
      json,
      context.clock.nowUtc(),
      email: email,
      tokenExpiry: tokenExpiry,
    );
  }
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
