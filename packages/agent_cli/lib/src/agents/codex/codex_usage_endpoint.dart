import '../adapter/agent_usage_endpoint.dart';
import '../data/usage_credentials.dart';
import '../data/usage_exception.dart';
import '../data/usage_throttle.dart';
import '../domain/agent_usage.dart';
import '../domain/usage_failure.dart';
import 'codex_rate_limit_reader.dart';

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
      io: context.io,
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

/// Parses Codex's `/backend-api/wham/usage` response. Each rate-limit window
/// is labelled by its own `limit_window_seconds`, else by its position.
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
        final seconds = w['limit_window_seconds'];
        final length = seconds is num
            ? Duration(seconds: seconds.round())
            : null;
        windows.add(
          UsageWindow(
            label: length == null ? label : codexWindowLabel(length),
            percent: (w['used_percent'] as num).toDouble(),
            resetsAt: _codexReset(w, now),
            span: length == null ? span : codexNominalSpan(length),
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
    // An instant: UTC, so it serialises with its `Z` as Claude's do.
    return DateTime.fromMillisecondsSinceEpoch(
      resetAt.toInt() * 1000,
      isUtc: true,
    );
  }
  final after = window['reset_after_seconds'];
  if (after is num) return now.toUtc().add(Duration(seconds: after.toInt()));
  return null;
}
