import '../adapter/agent_usage_endpoint.dart';
import '../data/usage_credentials.dart';
import '../data/usage_exception.dart';
import '../data/usage_throttle.dart';
import '../domain/agent_usage.dart';
import '../domain/usage_failure.dart';

/// Codex's usage: `GET https://chatgpt.com/backend-api/wham/usage` with the
/// `tokens.access_token` from `.codex/auth.json`. Read, never written, never
/// logged.
class CodexUsageEndpoint implements AgentUsageEndpoint {
  const CodexUsageEndpoint();

  static final _url = Uri.parse('https://chatgpt.com/backend-api/wham/usage');

  @override
  Future<AgentUsage> read(UsageReadContext context) async {
    final home = context.storeHome;
    if (home == null) {
      throw UsageException(
        'No Codex store for this install.',
        kind: UsageFailureKind.notAsked,
      );
    }
    final auth = await readUsageCredential(
      context.paths.join(home, 'auth.json'),
    );
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
    final emailFromToken = emailFromJwt(idToken);

    final json = await context.http.getJson(_url, {
      'Authorization': 'Bearer $token',
    });
    return parseCodexUsage(
      json,
      context.clock.nowUtc(),
      email: (json['email'] as String?) ?? emailFromToken,
    );
  }
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

DateTime? _codexReset(Map<String, dynamic> window, DateTime now) {
  final resetAt = window['reset_at'];
  if (resetAt is num) {
    return DateTime.fromMillisecondsSinceEpoch(resetAt.toInt() * 1000);
  }
  final after = window['reset_after_seconds'];
  if (after is num) return now.add(Duration(seconds: after.toInt()));
  return null;
}
