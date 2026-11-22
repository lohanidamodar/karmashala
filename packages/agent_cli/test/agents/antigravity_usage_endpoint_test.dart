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
  _QuotaService(this.answer, {this.formAnswer})
    : super(
        newClient: FakeHttpClient.new,
        clock: FixedClock(DateTime.utc(2026, 9, 28)),
      );

  final Map<String, dynamic> Function(Uri url, Map<String, String> headers)
  answer;
  final Map<String, dynamic> Function(Uri url, Map<String, String> fields)?
  formAnswer;
  final List<Uri> asked = [];
  final List<Uri> getAsked = [];
  final List<Map<String, String>> formAsked = [];

  @override
  Future<Map<String, dynamic>> postJson(
    Uri url,
    Map<String, String> headers,
    Object body,
  ) async {
    asked.add(url);
    if (!(headers['Client-Metadata'] ?? '').contains('ANTIGRAVITY')) {
      throw UsageException(
        'Usage request failed (HTTP 403).',
        kind: UsageFailureKind.unusable,
      );
    }
    return answer(url, headers);
  }

  @override
  Future<Map<String, dynamic>> postFormJson(
    Uri url,
    Map<String, String> fields, {
    Map<String, String> headers = const {},
  }) async {
    formAsked.add(fields);
    if (formAnswer case final fn?) return fn(url, fields);
    throw UsageException('Unexpected form post to $url');
  }

  @override
  Future<Map<String, dynamic>> getJson(
    Uri url,
    Map<String, String> headers,
  ) async {
    getAsked.add(url);
    return const {'email': 'dev@google.com'};
  }
}

String _fakeJwt(Map<String, Object?> payload) {
  final header = base64Url.encode(utf8.encode('{"alg":"none"}'));
  final body = base64Url.encode(utf8.encode(jsonEncode(payload)));
  return '$header.$body.sig';
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

  UsageReadContext contextOver(
    UsageHttp http, {
    String? storeHome,
    String? executablePath,
    UsageExecutableRunner? runExecutable,
  }) => UsageReadContext(
    storeHome: storeHome ?? home.path,
    paths: p.context,
    localMacHost: false,
    http: http,
    clock: FixedClock(now),
    keychain: ClaudeKeychainCache(
      read: () async => fail('Antigravity has no Keychain credential'),
    ),
    io: const LocalAuthFileIo(),
    executablePath: executablePath,
    runExecutable: runExecutable,
  );

  test(
    'asks as the Antigravity IDE, and reads the summary it answers',
    () async {
      final http = _QuotaService(
        (_, _) => {
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

  test('reads id_token_email directly without calling tokeninfo', () async {
    File(p.join(home.path, 'antigravity-oauth-token')).writeAsStringSync(
      jsonEncode({
        'token': {'access_token': 'made-up', 'expiry': '2026-09-29T00:00:00Z'},
        'id_token_email': 'direct@example.com',
      }),
    );
    final http = _QuotaService(
      (_, _) => {
        'groups': [
          {
            'displayName': 'Gemini Models',
            'buckets': [
              {
                'bucketId': 'gemini-5h',
                'window': '5h',
                'remainingFraction': 0.8,
              },
            ],
          },
        ],
      },
    );

    final usage = await const AntigravityUsageEndpoint().read(
      contextOver(http),
    );

    expect(usage.email, 'direct@example.com');
    expect(http.getAsked, isEmpty);
  });

  test('supplements summary with Gemini buckets from retrieveUserQuota when '
      'summary omits Gemini', () async {
    final http = _QuotaService((url, _) {
      if (url.path == '/v1internal:retrieveUserQuotaSummary') {
        return {
          'groups': [
            {
              'displayName': 'Claude and GPT models',
              'buckets': [
                {
                  'bucketId': 'cg-5h',
                  'window': '5h',
                  'remainingFraction': 0.9,
                  'resetTime': '2026-09-28T05:00:00Z',
                },
                {
                  'bucketId': 'cg-7d',
                  'window': '7d',
                  'remainingFraction': 0.75,
                  'resetTime': '2026-10-05T00:00:00Z',
                },
              ],
            },
          ],
        };
      }
      if (url.path == '/v1internal:retrieveUserQuota') {
        return {
          'buckets': [
            {
              'modelId': 'gemini-4-neon-high',
              'remainingFraction': 0.4,
              'resetTime': '2026-09-28T04:00:00Z',
            },
            {
              'modelId': 'gemini-3.8-flash-high',
              'remainingFraction': 0.95,
              'resetTime': '2026-09-28T05:00:00Z',
            },
            {
              'modelId': 'tab_autocomplete',
              'remainingFraction': 0.1,
            },
          ],
        };
      }
      fail('unexpected path ${url.path}');
    });

    final usage = await const AntigravityUsageEndpoint().read(
      contextOver(http),
    );

    expect(usage.windows.map((w) => w.label), [
      'Gemini · 5-hour',
      'Claude + GPT · 5-hour',
      'Claude + GPT · 7d',
    ]);
    expect(usage.windows[0].percent, closeTo(60, 0.01));
    expect(usage.windows[0].resetsAt, DateTime.utc(2026, 9, 28, 4));
    expect(usage.windows[1].percent, closeTo(10, 0.01));
    expect(usage.windows[2].percent, closeTo(25, 0.01));
  });

  test('an expired token is a sign-in failure, and nothing is asked', () async {
    File(p.join(home.path, 'antigravity-oauth-token')).writeAsStringSync(
      jsonEncode({
        'token': {'access_token': 'made-up', 'expiry': '2026-09-27T00:00:00Z'},
      }),
    );
    final http = _QuotaService((_, _) => fail('an expired token is not sent'));

    await expectLater(
      const AntigravityUsageEndpoint().read(contextOver(http)),
      throwsA(
        isA<UsageException>()
            .having((e) => e.kind, 'kind', UsageFailureKind.auth)
            .having((e) => e.message, 'message', contains('expired')),
      ),
    );
    expect(http.asked, isEmpty);
  });

  test('an expired agy token refreshes once via `agy models` and succeeds', () async {
    final tokenFile = File(p.join(home.path, 'antigravity-oauth-token'));
    tokenFile.writeAsStringSync(
      jsonEncode({
        'token': {'access_token': 'old-tok', 'expiry': '2026-09-27T00:00:00Z'},
      }),
    );
    final ran = <List<String>>[];
    final http = _QuotaService((_, headers) {
      expect(headers['Authorization'], 'Bearer fresh-tok');
      return {
        'groups': [
          {
            'displayName': 'Gemini Models',
            'buckets': [
              {'bucketId': 'g', 'window': '5h', 'remainingFraction': 0.7},
            ],
          },
        ],
      };
    });

    final usage = await const AntigravityUsageEndpoint().read(
      contextOver(
        http,
        executablePath: '/home/u/.local/bin/agy',
        runExecutable: (args, {timeout = const Duration(seconds: 20)}) async {
          ran.add(args);
          tokenFile.writeAsStringSync(
            jsonEncode({
              'token': {
                'access_token': 'fresh-tok',
                'expiry': '2026-09-29T00:00:00Z',
              },
              'id_token_email': 'refreshed@example.com',
            }),
          );
          return true;
        },
      ),
    );

    expect(ran, [
      ['models'],
    ]);
    expect(usage.email, 'refreshed@example.com');
    expect(usage.windows.single.percent, closeTo(30, 0.01));
  });

  test('does not run `models` refresh on standalone agy_acp_server', () async {
    File(p.join(home.path, 'antigravity-oauth-token')).writeAsStringSync(
      jsonEncode({
        'token': {'access_token': 'old-tok', 'expiry': '2026-09-27T00:00:00Z'},
      }),
    );
    var ran = false;
    final http = _QuotaService((_, _) => fail('should not call quota'));

    await expectLater(
      const AntigravityUsageEndpoint().read(
        contextOver(
          http,
          executablePath: r'C:\karmashala\acp\antigravity-acp\agy_acp_server.exe',
          runExecutable: (_, {timeout = const Duration(seconds: 20)}) async {
            ran = true;
            return true;
          },
        ),
      ),
      throwsA(
        isA<UsageException>().having(
          (e) => e.kind,
          'kind',
          UsageFailureKind.auth,
        ),
      ),
    );
    expect(ran, isFalse);
  });

  test('exchanges acp_token.json refresh_token in memory and reads quota', () async {
    final acpHome = Directory.systemTemp.createTempSync('agy_acp_usage');
    addTearDown(() => acpHome.deleteSync(recursive: true));
    File(p.join(acpHome.path, 'acp_token.json')).writeAsStringSync(
      jsonEncode({
        'client_id': 'test-client-id',
        'client_secret': 'test-client-secret',
        'refresh_token': 'test-refresh-token',
        'token_uri': 'https://oauth2.googleapis.com/token',
      }),
    );

    final http = _QuotaService(
      (url, headers) {
        expect(headers['Authorization'], 'Bearer exchanged-access');
        return {
          'groups': [
            {
              'displayName': 'Gemini Models',
              'buckets': [
                {
                  'bucketId': 'g-5h',
                  'window': '5h',
                  'remainingFraction': 0.25,
                },
              ],
            },
          ],
        };
      },
      formAnswer: (url, fields) {
        expect(url.toString(), 'https://oauth2.googleapis.com/token');
        expect(fields['grant_type'], 'refresh_token');
        expect(fields['refresh_token'], 'test-refresh-token');
        return {
          'access_token': 'exchanged-access',
          'expires_in': 3600,
          'id_token': _fakeJwt({'email': 'acp-user@example.com'}),
        };
      },
    );

    final usage = await const AntigravityUsageEndpoint().read(
      contextOver(http, storeHome: acpHome.path),
    );

    expect(http.formAsked, hasLength(1));
    expect(usage.email, 'acp-user@example.com');
    expect(usage.windows.single.label, 'Gemini · 5-hour');
    expect(usage.windows.single.percent, closeTo(75, 0.01));
    expect(usage.tokenExpiresAt, now.add(const Duration(seconds: 3600)));
  });

  test('a refused quota is reported as refused, never as a tier', () async {
    final http = _QuotaService(
      (_, _) => throw UsageException('Usage request failed (HTTP 403).'),
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

  group('UsageHttp.postJson error classification', () {
    test('classifies 401 as auth, 429 as rateLimited, and 503 as serverBusy', () async {
      UsageHttp httpReturning(int status, {Map<String, String> headers = const {}}) =>
          UsageHttp(
            newClient: () => FakeHttpClient(
              statusCode: status,
              body: '{}',
              responseHeaders: headers,
            ),
            clock: FixedClock(now),
          );

      await expectLater(
        httpReturning(401).postJson(Uri.https('example.com', '/q'), const {}, const {}),
        throwsA(
          isA<UsageException>().having(
            (e) => e.kind,
            'kind',
            UsageFailureKind.auth,
          ),
        ),
      );
      await expectLater(
        httpReturning(429, headers: const {'retry-after': '120'}).postJson(
          Uri.https('example.com', '/q'),
          const {},
          const {},
        ),
        throwsA(
          isA<UsageException>()
              .having((e) => e.kind, 'kind', UsageFailureKind.rateLimited)
              .having((e) => e.retryIn, 'retryIn', const Duration(seconds: 120)),
        ),
      );
      await expectLater(
        httpReturning(503).postJson(Uri.https('example.com', '/q'), const {}, const {}),
        throwsA(
          isA<UsageException>().having(
            (e) => e.kind,
            'kind',
            UsageFailureKind.serverBusy,
          ),
        ),
      );
    });
  });
}
