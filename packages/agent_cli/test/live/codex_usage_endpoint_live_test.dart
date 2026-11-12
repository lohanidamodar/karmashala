@Tags(['live'])
library;

import 'dart:io';

import 'package:agent_cli/src/agents/adapter/agent_usage_endpoint.dart';
import 'package:agent_cli/src/util/clock.dart';
import 'package:agent_cli/usage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Codex's real usage endpoint, called through [CodexUsageEndpoint] with this
/// machine's sign-in. Opt-in (KARMASHALA_LIVE_USAGE=1): it prints only the key
/// names and value types of each window — never a value, header or account.
void main() {
  final enabled = Platform.environment['KARMASHALA_LIVE_USAGE'] == '1';
  final home =
      Platform.environment['CODEX_HOME'] ??
      p.join(
        Platform.environment['USERPROFILE'] ??
            Platform.environment['HOME'] ??
            '',
        '.codex',
      );

  test('the usage payload names how long each window is', () async {
    final http = _ShapeRecorder();
    try {
      await const CodexUsageEndpoint().read(
        UsageReadContext(
          storeHome: home,
          paths: p.context,
          localMacHost: false,
          http: http,
          clock: const SystemClock(),
          keychain: ClaudeKeychainCache(
            read: () async => const ClaudeKeychainRead.notFound(),
          ),
          io: const LocalAuthFileIo(),
        ),
      );
    } on UsageException catch (e) {
      fail('Usage read failed: ${e.kind}');
    } catch (e) {
      // Its type only: a message could quote the response.
      fail('Usage read failed: ${e.runtimeType}');
    }
    final rateLimit = http.payload?['rate_limit'];
    if (rateLimit is! Map<String, dynamic>) {
      fail('rate_limit is ${rateLimit.runtimeType}');
    }
    for (final key in const ['primary_window', 'secondary_window']) {
      final window = rateLimit[key];
      final shape = window is Map<String, dynamic>
          ? {
              for (final e in window.entries)
                e.key: e.value.runtimeType.toString(),
            }
          : window.runtimeType.toString();
      print('$key: $shape');
    }
  }, skip: enabled ? false : 'Set KARMASHALA_LIVE_USAGE=1 to call Codex.');
}

/// The real HTTP client, keeping the decoded payload for the shape print.
class _ShapeRecorder extends UsageHttp {
  _ShapeRecorder()
    : super(newClient: HttpClient.new, clock: const SystemClock());

  Map<String, dynamic>? payload;

  @override
  Future<Map<String, dynamic>> getJson(
    Uri url,
    Map<String, String> headers,
  ) async => payload = await super.getJson(url, headers);
}
