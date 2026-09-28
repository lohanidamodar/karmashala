import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/agents/adapter/agent_usage_endpoint.dart';
import 'package:agent_cli/usage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_http_client.dart';
import '../support/fakes.dart';

/// The quota service answers only a caller that says it is the Antigravity
/// IDE; anything else gets `SUBSCRIPTION_REQUIRED`. This one answers the same
/// way, so the endpoint is held to sending who it is — and to saying so when
/// it is refused, rather than showing the tier `loadCodeAssist` names.
class _QuotaService extends UsageHttp {
  _QuotaService(this.answer)
    : super(
        newClient: FakeHttpClient.new,
        clock: FixedClock(DateTime.utc(2026, 9, 28)),
      );

  final Map<String, dynamic> Function(Uri url) answer;
  final List<Uri> asked = [];

  @override
  Future<Map<String, dynamic>> postJson(
    Uri url,
    Map<String, String> headers,
    Object body,
  ) async {
    asked.add(url);
    if (!(headers['Client-Metadata'] ?? '').contains('ANTIGRAVITY')) {
      throw UsageException('Usage request failed (HTTP 403).');
    }
    return answer(url);
  }

  @override
  Future<Map<String, dynamic>> getJson(
    Uri url,
    Map<String, String> headers,
  ) async => const {'email': 'dev@google.com'};
}

void main() {
  late Directory home;
  final now = DateTime.utc(2026, 9, 28);

  setUp(() {
    home = Directory.systemTemp.createTempSync('agy_usage');
    File(p.join(home.path, 'antigravity-oauth-token')).writeAsStringSync(
      jsonEncode({
        'token': {'access_token': 'made-up', 'expiry': '2026-09-29T00:00:00Z'},
      }),
    );
  });
  tearDown(() => home.deleteSync(recursive: true));

  UsageReadContext contextOver(UsageHttp http) => UsageReadContext(
    storeHome: home.path,
    paths: p.context,
    localMacHost: false,
    http: http,
    clock: FixedClock(now),
    keychain: ClaudeKeychainCache(
      read: () async => fail('Antigravity has no Keychain credential'),
    ),
    io: const LocalAuthFileIo(),
  );

  test(
    'asks as the Antigravity IDE, and reads the summary it answers',
    () async {
      final http = _QuotaService(
        (_) => {
          'groups': [
            {
              'displayName': 'Gemini Models',
              'buckets': [
                {
                  'bucketId': 'gemini-5h',
                  'window': '5h',
                  'remainingFraction': 0.5,
                },
              ],
            },
          ],
        },
      );

      final usage = await const AntigravityUsageEndpoint().read(
        contextOver(http),
      );

      expect(usage.windows.single.label, 'Gemini · 5-hour');
      expect(usage.windows.single.percent, 50);
      expect(usage.email, 'dev@google.com');
      expect(http.asked.single.path, '/v1internal:retrieveUserQuotaSummary');
    },
  );

  test('a refused quota is reported as refused, never as a tier', () async {
    final http = _QuotaService(
      (_) => throw UsageException('Usage request failed (HTTP 403).'),
    );

    await expectLater(
      const AntigravityUsageEndpoint().read(contextOver(http)),
      throwsA(
        isA<UsageException>().having(
          (e) => e.message,
          'message',
          contains('403'),
        ),
      ),
    );
    expect(
      http.asked.map((u) => u.path),
      everyElement('/v1internal:retrieveUserQuotaSummary'),
      reason: 'both hosts asked; loadCodeAssist never is',
    );
  });
}
