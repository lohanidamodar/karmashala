import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/usage.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';

import '../../support/fake_cli_store_locator.dart';
import '../../support/fakes.dart';
import '../../support/fake_http_client.dart';
import '../../support/fixtures.dart';
import 'package:agent_cli/read.dart';

const _usageBody = '{"five_hour": {"utilization": 42.0}}';

void main() {
  final now = DateTime.utc(2026, 7, 28, 12);

  group('parseClaudeUsage', () {
    test('maps present named windows with utilization to UsageWindows', () {
      final usage = parseClaudeUsage({
        'five_hour': {'utilization': 42.0, 'resets_at': '2026-07-28T17:00:00Z'},
        'seven_day': {'utilization': 13.5, 'resets_at': null},
        'seven_day_opus': {'utilization': 0.0, 'resets_at': null},
        // sonnet absent → skipped
      }, now);

      expect(usage.windows.map((w) => w.label).toList(), [
        '5-hour',
        '7-day',
        'Opus · 7-day',
      ]);
      expect(usage.windows.first.percent, 42.0);
      expect(usage.windows.first.resetsAt, DateTime.utc(2026, 7, 28, 17));
      expect(usage.windows[1].resetsAt, isNull);
      expect(usage.fetchedAt, now);
    });

    test('adds per-model weekly limits and drops the session mirror', () {
      final usage = parseClaudeUsage({
        'five_hour': {'utilization': 8, 'resets_at': null},
        'seven_day': null,
        'limits': [
          // Mirrors five_hour — must be dropped.
          {'kind': 'session', 'group': 'session', 'percent': 8},
          {
            'kind': 'weekly_scoped',
            'group': 'weekly',
            'percent': 0,
            'scope': {
              'model': {'display_name': 'Fable'},
            },
          },
        ],
      }, now);

      expect(usage.windows.map((w) => w.label).toList(), [
        '5-hour',
        'Fable · weekly',
      ]);
    });

    test('includes extra usage only when enabled', () {
      final enabled = parseClaudeUsage({
        'five_hour': {'utilization': 1},
        'extra_usage': {'is_enabled': true, 'utilization': 12.0},
      }, now);
      expect(enabled.windows.last.label, 'Extra usage');
      expect(enabled.windows.last.percent, 12.0);

      final disabled = parseClaudeUsage({
        'five_hour': {'utilization': 1},
        'extra_usage': {'is_enabled': false, 'utilization': 12.0},
      }, now);
      expect(
        disabled.windows.map((w) => w.label),
        isNot(contains('Extra usage')),
      );
    });

    test('is empty when no windows are present', () {
      final usage = parseClaudeUsage({'other': 1}, now);
      expect(usage.isEmpty, isTrue);
    });
  });

  group('parseCodexUsage', () {
    test('maps primary/secondary windows and computes resets', () {
      final usage = parseCodexUsage({
        'email': 'me@openai.com',
        'rate_limit': {
          'primary_window': {'used_percent': 30.0, 'reset_after_seconds': 3600},
          'secondary_window': {
            'used_percent': 66.0,
            'reset_at': 1785325200, // epoch seconds
          },
        },
      }, now);

      expect(usage.email, 'me@openai.com');
      expect(usage.windows.map((w) => w.label).toList(), ['5-hour', '7-day']);
      expect(usage.windows[0].percent, 30.0);
      expect(usage.windows[0].resetsAt, now.add(const Duration(hours: 1)));
      expect(
        usage.windows[1].resetsAt,
        DateTime.fromMillisecondsSinceEpoch(1785325200 * 1000),
      );
    });

    test('is empty when rate_limit is missing', () {
      expect(parseCodexUsage({'email': 'x'}, now).isEmpty, isTrue);
    });
  });

  group('parseAntigravityUsage', () {
    // **What `loadCodeAssist` actually carries.** `allowedTiers` names the
    // tiers the account is allowed — `id`, `name`, `description` — and nothing
    // in the reply counts anything: no used/limit pair, no remaining, no reset.
    // So the windows it produces are labels, and the percent every surface
    // draws is absent rather than zero.
    test('names each tier and claims no quota for it', () {
      final expiry = DateTime.utc(2026, 7, 28, 13);
      final usage = parseAntigravityUsage(
        {
          'allowedTiers': [
            {
              'id': 'standard-tier',
              'name': 'Gemini Code Assist',
              'description': 'Unlimited coding assistant',
            },
            {'id': 'legacy-tier', 'name': 'Code Assist (legacy)'},
          ],
        },
        now,
        email: 'dev@google.com',
        tokenExpiry: expiry,
      );

      expect(usage.email, 'dev@google.com');
      expect(usage.windows.map((w) => w.label).toList(), [
        'Gemini Code Assist',
        'Code Assist (legacy)',
      ]);
      expect(
        usage.windows.map((w) => w.percent),
        everyElement(isNull),
        reason: 'nothing measured these, and 0.0 said something else',
      );
      expect(usage.isEmpty, isFalse, reason: 'the tiers themselves are known');
    });

    test('the token expiry is the account\'s, not a window\'s reset', () {
      // It used to be written into `resetsAt`, so the app said a quota it had
      // never read would reset the moment the user's sign-in lapsed. Two
      // different facts, and only one of them puts a number back to zero.
      final expiry = DateTime.utc(2026, 7, 28, 13);
      final usage = parseAntigravityUsage(
        {
          'allowedTiers': [
            {'id': 'standard-tier', 'name': 'Gemini Code Assist'},
          ],
        },
        now,
        tokenExpiry: expiry,
      );

      expect(usage.tokenExpiresAt, expiry);
      expect(usage.windows.single.resetsAt, isNull);
      expect(
        usage.windows.single.span,
        isNull,
        reason: 'a tier is not a period, so it cannot bound the ask rate',
      );
    });

    test(
      'falls back to default Code Assist window when allowedTiers is empty',
      () {
        final usage = parseAntigravityUsage({}, now, email: 'test@example.com');
        expect(usage.windows.single.label, 'Gemini Code Assist');
        expect(usage.windows.single.percent, isNull);
        expect(usage.email, 'test@example.com');
      },
    );
  });

  group('parseRetryAfter', () {
    test('reads the delay form', () {
      expect(parseRetryAfter('120', now), const Duration(minutes: 2));
      expect(parseRetryAfter(' 30 ', now), const Duration(seconds: 30));
    });

    test('reads the HTTP-date form, as of now', () {
      final until = HttpDate.format(now.add(const Duration(minutes: 5)));
      expect(parseRetryAfter(until, now), const Duration(minutes: 5));
    });

    test('a date already past is no wait at all, never a negative one', () {
      final until = HttpDate.format(now.subtract(const Duration(minutes: 5)));
      expect(parseRetryAfter(until, now), Duration.zero);
      expect(parseRetryAfter('-30', now), Duration.zero);
    });

    test('is null when the header is absent or unreadable', () {
      // Neither endpoint promises the header, so the caller has to have its own
      // answer; saying "wait zero" here would be that answer, wrongly.
      expect(parseRetryAfter(null, now), isNull);
      expect(parseRetryAfter('', now), isNull);
      expect(parseRetryAfter('soon', now), isNull);
    });
  });

  /// **What a non-200 means, and what the app does next.**
  ///
  /// Every case below is served by `FakeHttpClient`: the endpoints under test
  /// are the vendors' own, and the owner was rate limited when this was
  /// written — asking them to prove a backoff is the one thing a backoff exists
  /// to stop.
  group('the answer the endpoint gave', () {
    late MovableClock clock;
    late FakeHttpClient http;

    setUp(() {
      clock = MovableClock(testTime);
      http = FakeHttpClient(statusCode: 200, body: _usageBody);
    });

    AgentUsageService serviceWith() => AgentUsageService(
      storeLocator: FixedLocator([
        const CliStore(
          environmentId: 'windows',
          homesByAgentId: {'claudeCode': '/Users/me/.claude'},
        ),
      ]),
      clock: clock,
      httpClientFactory: () => http,
      // The credential comes from a fake Keychain rather than a file, so
      // nothing here reads or writes a real store.
      keychain: ClaudeKeychainCache(
        read: () async => ClaudeKeychainRead(
          ClaudeKeychainOutcome.found,
          secret: jsonEncode({
            'claudeAiOauth': {'accessToken': 'token'},
          }),
        ),
      ),
      hostIsMacOS: true,
      throttle: UsageThrottle(clock: clock, jitter: () => 0),
    );

    Future<UsageException> failureOf(
      AgentUsageService service, {
      AgentInstallation? installation,
    }) async {
      try {
        await service.fetch(installation ?? agentInstallation(), [posixEnv()]);
      } on UsageException catch (e) {
        return e;
      }
      fail('expected the fetch to fail');
    }

    test('a Keychain refusal is not a signed-out account, and carries its '
        'age', () async {
      // The memo holds a refusal for ten minutes on purpose — caching only
      // successes would re-raise the dialog on every poll — so what the chip
      // shows can be that old and has to say so.
      final askedAt = testTime.subtract(const Duration(minutes: 7));
      final service = AgentUsageService(
        storeLocator: FixedLocator([
          const CliStore(
            environmentId: 'windows',
            homesByAgentId: {'claudeCode': '/Users/me/.claude'},
          ),
        ]),
        clock: clock,
        httpClientFactory: () => http,
        keychain: ClaudeKeychainCache(
          read: () async => const ClaudeKeychainRead(
            ClaudeKeychainOutcome.refused,
            detail: 'User interaction is not allowed.',
          ),
          now: () => askedAt,
        ),
        hostIsMacOS: true,
        throttle: UsageThrottle(clock: clock, jitter: () => 0),
      );

      final failure = await failureOf(service);
      expect(failure.kind, UsageFailureKind.auth);
      expect(
        failure.message,
        allOf(
          contains('Keychain'),
          contains('User interaction is not allowed.'),
          contains('7m ago'),
          isNot(contains('Not signed in')),
        ),
      );
    });

    test('429 is a rate limit, and the next ask never leaves the '
        'machine', () async {
      http.statusCode = HttpStatus.tooManyRequests;
      final service = serviceWith();

      final first = await failureOf(service);
      expect(first.kind, UsageFailureKind.rateLimited);
      expect(first.retryIn, kUsageBackoffBase);
      expect(
        first.message,
        'Rate limited by the usage service. Waiting 1m before asking again.',
      );
      expect(http.requests, 1);

      // The bug this fixes: the poll kept firing into the limit at the rate
      // that caused it.
      final second = await failureOf(service);
      expect(second.kind, UsageFailureKind.rateLimited);
      expect(
        http.requests,
        1,
        reason: 'a backoff that still makes the request is not a backoff',
      );

      clock.advance(kUsageBackoffBase);
      http.statusCode = HttpStatus.ok;
      final usage = await service.fetch(agentInstallation(), [posixEnv()]);
      expect(usage.windows, hasLength(1));
      expect(http.requests, 2);
    });

    test('a Retry-After the server sent decides the wait', () async {
      http
        ..statusCode = HttpStatus.tooManyRequests
        ..responseHeaders = {'Retry-After': '120'};
      final service = serviceWith();

      final failure = await failureOf(service);
      expect(failure.retryIn, const Duration(minutes: 2));
      expect(failure.message, contains('Waiting 2m'));

      clock.advance(const Duration(seconds: 119));
      expect((await failureOf(service)).kind, UsageFailureKind.rateLimited);
      expect(http.requests, 1, reason: 'the server said two minutes');

      clock.advance(const Duration(seconds: 1));
      await failureOf(service);
      expect(http.requests, 2);
    });

    test('a limit on one account leaves the other askable', () async {
      // Claude and Codex are two accounts and two endpoints; one vendor
      // throttling us says nothing about the other. Two environments are two
      // accounts for the same reason.
      http.statusCode = HttpStatus.tooManyRequests;
      final service = serviceWith();
      await failureOf(service);

      expect(service.pendingPause(agentInstallation()), isNotNull);
      expect(
        service.pendingPause(
          agentInstallation(id: 'a2', agentId: AgentIds.codex),
        ),
        isNull,
      );
      expect(
        service.pendingPause(
          agentInstallation(id: 'a3', environmentId: 'wsl:Ubuntu'),
        ),
        isNull,
      );
    });

    test('401 is a sign-in problem, and is retried at the usual '
        'cadence', () async {
      http.statusCode = HttpStatus.unauthorized;
      final service = serviceWith();

      final failure = await failureOf(service);
      expect(failure.kind, UsageFailureKind.auth);
      expect(failure.message, contains('Access token expired'));

      // Deliberately no backoff: the user fixes this by running the agent once,
      // and a chip that took sixteen minutes to notice would be useless.
      await failureOf(service);
      expect(http.requests, 2);
    });

    test('a 5xx is waited out too, and is not called a rate limit', () async {
      // The owner's own failure was upstream and self-resolving. Pushing on a
      // server that is already struggling is the same mistake as pushing on one
      // that is throttling us — but the user is not being throttled, and must
      // not be told they are.
      http.statusCode = HttpStatus.serviceUnavailable;
      final service = serviceWith();
      final failure = await failureOf(service);

      expect(failure.kind, UsageFailureKind.serverBusy);
      expect(failure.message, contains('having trouble (HTTP 503)'));
      expect(failure.message, contains('Waiting 1m'));
      expect(failure.retryIn, kUsageBackoffBase);

      await failureOf(service);
      expect(http.requests, 1, reason: 'the wait holds for a 5xx as well');
    });

    test('an unexpected status under 500 is unusable, and is not waited '
        'out', () async {
      // Nothing about a 418 says the server is unwell or that we are being
      // throttled, so it is reported and retried at the usual cadence.
      http.statusCode = 418;
      final service = serviceWith();
      final failure = await failureOf(service);

      expect(failure.kind, UsageFailureKind.unusable);
      expect(failure.message, contains('HTTP 418'));
      expect(failure.retryIn, isNull);

      await failureOf(service);
      expect(http.requests, 2);
    });

    test('a body that is not JSON is unusable, not unreachable', () async {
      // Telling the user to check their network over a malformed body sends
      // them somewhere there is nothing to find.
      http.body = '<html>nope</html>';
      final failure = await failureOf(serviceWith());

      expect(failure.kind, UsageFailureKind.unusable);
      expect(failure.message, contains('could not read'));
    });

    test('a socket that never answered is unreachable', () async {
      http.throwOnRequest = const SocketException('failed host lookup');
      final failure = await failureOf(serviceWith());

      expect(failure.kind, UsageFailureKind.unreachable);
      expect(failure.message, contains('Could not reach'));
    });

    test('an agent with no usage endpoint was never asked', () async {
      final service = serviceWith();
      final failure = await failureOf(
        service,
        installation: agentInstallation(id: 'a9', agentId: 'unknownAgent'),
      );

      expect(failure.kind, UsageFailureKind.notAsked);
      expect(http.requests, 0);
    });

    test('a reading survives the rate limit that follows it, with its '
        'own age', () async {
      final service = serviceWith();
      await service.fetch(agentInstallation(), [posixEnv()]);
      clock.advance(const Duration(minutes: 4));
      http.statusCode = HttpStatus.tooManyRequests;
      await failureOf(service);

      final remembered = service.remembered(agentInstallation());
      expect(remembered?.windows.single.percent, 42.0);
      expect(
        remembered?.fetchedAt,
        testTime,
        reason: 'four minutes old, and it says so rather than looking live',
      );
      expect(
        service.rememberedIfFresh(agentInstallation()),
        isNull,
        reason: 'too old to stand in for a fetch, not too old to show',
      );
    });

    test('the floor is read off the payload, not off a constant', () async {
      final service = serviceWith();
      await service.fetch(agentInstallation(), [posixEnv()]);
      expect(http.requests, 1);

      // `_usageBody` is a `five_hour` window, so one point of it is three
      // minutes. Nothing chose that number; the key did.
      expect(service.askFloor(agentInstallation()), const Duration(minutes: 3));
      expect(service.rememberedIfFresh(agentInstallation()), isNotNull);
      clock.advance(kUsageMinInterval);
      expect(
        service.rememberedIfFresh(agentInstallation()),
        isNotNull,
        reason: 'a minute in, a request could not have learned a point',
      );
      clock.advance(const Duration(minutes: 2));
      expect(service.rememberedIfFresh(agentInstallation()), isNull);
    });

    test('**no caller can ask twice inside the floor**', () async {
      // The property the whole rate-limit fix rests on. `fetch` is the only
      // door, and the floor is behind it rather than in front of each caller —
      // the tick, the chip's click, a status change, the Settings button, the
      // fan-out dialog and the MCP tool all arrive here, and four of them used
      // to arrive unconditionally.
      final service = serviceWith();
      await service.fetch(agentInstallation(), [posixEnv()]);
      expect(http.requests, 1);

      for (var i = 0; i < 20; i++) {
        clock.advance(const Duration(seconds: 8));
        await service.fetch(agentInstallation(), [posixEnv()]);
      }
      expect(
        http.requests,
        1,
        reason: 'twenty asks across 160 seconds, one request',
      );

      clock.advance(const Duration(minutes: 3));
      await service.fetch(agentInstallation(), [posixEnv()]);
      expect(http.requests, 2, reason: 'past the floor it asks for real');
    });

    test('a served reading is the one that was read, age and all', () async {
      final service = serviceWith();
      final first = await service.fetch(agentInstallation(), [posixEnv()]);
      clock.advance(const Duration(minutes: 1));
      final second = await service.fetch(agentInstallation(), [posixEnv()]);

      expect(http.requests, 1);
      expect(
        second.fetchedAt,
        first.fetchedAt,
        reason: 'nothing here invents a fresher timestamp for an old number',
      );
    });

    test('nothing is remembered before the first reading', () {
      final service = serviceWith();
      expect(service.remembered(agentInstallation()), isNull);
      expect(service.pendingPause(agentInstallation()), isNull);
    });
  });
}
