import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/util/clock.dart';
import '../../cli_detection/application/cli_detection_service.dart';
import '../../environments/domain/execution_environment.dart';
import '../domain/agent_installation.dart';
import '../domain/agent_kind.dart';
import '../domain/agent_usage.dart';

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
  }) : _newClient = httpClientFactory ?? HttpClient.new;

  final CliStoreLocator storeLocator;
  final Clock clock;
  final HttpClient Function() _newClient;

  static final _claudeUsageUrl = Uri.parse(
    'https://api.anthropic.com/api/oauth/usage',
  );
  static final _codexUsageUrl = Uri.parse(
    'https://chatgpt.com/backend-api/wham/usage',
  );

  /// Fetches usage for [installation]. Throws [UsageException] on any failure.
  Future<AgentUsage> fetch(
    AgentInstallation installation,
    List<ExecutionEnvironment> environments,
  ) async {
    if (installation.agentKind == AgentKind.antigravity) {
      throw UsageException('Usage is not available for Antigravity.');
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
        'Could not locate the store for ${installation.environmentId}.',
      );
    }

    switch (installation.agentKind) {
      case AgentKind.claudeCode:
        return _fetchClaude(store);
      case AgentKind.codex:
        return _fetchCodex(store);
      case AgentKind.antigravity:
        throw UsageException('Usage is not available for Antigravity.');
    }
  }

  Future<AgentUsage> _fetchClaude(CliStore store) async {
    final home = store.claudeHome;
    if (home == null) throw UsageException('No Claude store for this install.');
    final creds = await _readJson(p.windows.join(home, '.credentials.json'));
    final oauth = creds?['claudeAiOauth'];
    final token = oauth is Map<String, dynamic>
        ? oauth['accessToken'] as String?
        : null;
    if (token == null) {
      throw UsageException('Not signed in to Claude in this environment.');
    }
    final json = await _getJson(_claudeUsageUrl, {
      'Authorization': 'Bearer $token',
      'anthropic-beta': 'oauth-2025-04-20',
    });
    return parseClaudeUsage(json, clock.nowUtc());
  }

  Future<AgentUsage> _fetchCodex(CliStore store) async {
    final home = store.codexHome;
    if (home == null) throw UsageException('No Codex store for this install.');
    final auth = await _readJson(p.windows.join(home, 'auth.json'));
    final tokens = auth?['tokens'];
    final token = tokens is Map<String, dynamic>
        ? tokens['access_token'] as String?
        : null;
    if (token == null) {
      throw UsageException('Not signed in to Codex in this environment.');
    }
    final json = await _getJson(_codexUsageUrl, {
      'Authorization': 'Bearer $token',
    });
    return parseCodexUsage(json, clock.nowUtc());
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
