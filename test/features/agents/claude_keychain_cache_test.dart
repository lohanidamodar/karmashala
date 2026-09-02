import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/data/agent_usage_service.dart';
import 'package:karmashala/src/features/agents/data/claude_auth_service.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_service.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **What one glance at the quota chip costs the login Keychain.**
///
/// On macOS the Claude credential lives in the login Keychain, and reading it
/// spawns `security find-generic-password`. The status-bar chip polls once a
/// minute while the window is focused, and every poll used to spawn it again —
/// so a user who answered the access prompt with *Allow* rather than *Always
/// Allow* got a Keychain dialog a minute, for a secret the app already had.
///
/// Counted, never timed: spawns are countable exactly, and the suite runs at
/// `--concurrency=4` where a few milliseconds is a coin toss.

/// One `security` invocation, faked, and counted.
class _CountingKeychain {
  _CountingKeychain(this.answer);

  ClaudeKeychainRead answer;
  int reads = 0;

  Future<ClaudeKeychainRead> read() async {
    reads++;
    return answer;
  }
}

class _Movable {
  _Movable(this.now);
  DateTime now;
  DateTime call() => now;
}

/// The stores the service would have found, without touching a disk.
class _FixedStores extends CliStoreLocator {
  _FixedStores(this.stores)
    : super(
        runnerFactory: FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
      );

  final List<CliStore> stores;

  @override
  Future<List<CliStore>> locate(List<dynamic> environments) async => stores;
}

/// A response the service can read, without a socket.
class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.statusCode, this.body);

  @override
  final int statusCode;
  final String body;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(utf8.encode(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.response, this.sentAuthorization);

  final _FakeResponse response;
  final List<String?> sentAuthorization;

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  Future<HttpClientResponse> close() async {
    sentAuthorization.add((headers as _FakeHeaders).values['authorization']);
    return response;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHeaders implements HttpHeaders {
  final values = <String, String>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = '$value';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this.statusCode, this.body);

  int statusCode;
  String body;
  final sentAuthorization = <String?>[];
  int requests = 0;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests++;
    return _FakeRequest(_FakeResponse(statusCode, body), sentAuthorization);
  }

  /// The service closes its client in a `finally`, so this is on the path of
  /// every fetch including the failing ones.
  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _usageBody = '{"five_hour": {"utilization": 42.0}}';

String _credentials(String token) => jsonEncode({
  'claudeAiOauth': {'accessToken': token},
});

void main() {
  group('ClaudeKeychainCache', () {
    test('an hour of polling asks the Keychain once', () async {
      final security = _CountingKeychain(
        ClaudeKeychainRead(ClaudeKeychainOutcome.found, secret: '{}'),
      );
      final clock = _Movable(DateTime.utc(2026, 9, 2, 12));
      final cache = ClaudeKeychainCache(read: security.read, now: clock.call);

      // Sixty polls, one a minute, inside a ten-minute window... except the
      // window expires, so count what actually happens over the hour.
      for (var minute = 0; minute < 60; minute++) {
        clock.now = clock.now.add(const Duration(minutes: 1));
        await cache.read();
      }

      // Six, not sixty: one per lifetime. Before the memo this was one spawn —
      // and one possible Keychain dialog — per minute.
      expect(security.reads, 6);
    });

    test('a refusal is remembered, not re-asked', () async {
      final security = _CountingKeychain(
        const ClaudeKeychainRead(
          ClaudeKeychainOutcome.refused,
          detail: 'User interaction is not allowed.',
        ),
      );
      final clock = _Movable(DateTime.utc(2026, 9, 2, 12));
      final cache = ClaudeKeychainCache(read: security.read, now: clock.call);

      for (var i = 0; i < 5; i++) {
        await cache.read();
      }

      // The case that actually raises the dialog. Caching only successes would
      // have left exactly the bug this fixes: re-asking, every tick, the one
      // user who already said no.
      expect(security.reads, 1);
    });

    test('what it holds goes stale on time', () async {
      final security = _CountingKeychain(
        ClaudeKeychainRead(ClaudeKeychainOutcome.found, secret: 'first'),
      );
      final clock = _Movable(DateTime.utc(2026, 9, 2, 12));
      final cache = ClaudeKeychainCache(
        read: security.read,
        now: clock.call,
        lifetime: const Duration(minutes: 10),
      );

      expect((await cache.read()).secret, 'first');
      security.answer = ClaudeKeychainRead(
        ClaudeKeychainOutcome.found,
        secret: 'second',
      );

      clock.now = clock.now.add(const Duration(minutes: 9));
      expect((await cache.read()).secret, 'first', reason: 'still fresh');

      clock.now = clock.now.add(const Duration(minutes: 2));
      // A user who logs in again is picked up without restarting the app.
      expect((await cache.read()).secret, 'second');
      expect(security.reads, 2);
    });

    test('forgetting it asks again immediately', () async {
      final security = _CountingKeychain(
        ClaudeKeychainRead(ClaudeKeychainOutcome.found, secret: 'first'),
      );
      final cache = ClaudeKeychainCache(
        read: security.read,
        now: DateTime.utc(2026, 9, 2, 12).toLocal,
      );

      await cache.read();
      security.answer = ClaudeKeychainRead(
        ClaudeKeychainOutcome.found,
        secret: 'second',
      );
      cache.forget();

      // The clock has not moved: this is the caller saying the held copy is
      // provably wrong, which outranks the window.
      expect((await cache.read()).secret, 'second');
      expect(security.reads, 2);
    });
  });

  group('what one security run meant', () {
    test('a present item is the credential', () {
      final read = claudeKeychainReadOf(0, stdout: '{"claudeAiOauth":{}}\n');
      expect(read.outcome, ClaudeKeychainOutcome.found);
      expect(read.secret, '{"claudeAiOauth":{}}');
    });

    test('exit 44 is nobody logged in', () {
      // Read off the real tool on this machine: a missing service exits 44,
      // a present one exits 0. It is the only code that means "no account",
      // and folding any other failure into it is what produced "Not signed in"
      // in front of users who were.
      final read = claudeKeychainReadOf(
        44,
        stderr:
            'security: SecKeychainSearchCopyNext: The specified item '
            'could not be found in the keychain.',
      );
      expect(read.outcome, ClaudeKeychainOutcome.notFound);
      expect(read.detail, isNull);
    });

    test('any other failure is a refusal, in the tool\'s own words', () {
      final read = claudeKeychainReadOf(
        51,
        stderr:
            'security: SecKeychainSearchCopyNext: User interaction is not '
            'allowed.',
      );
      expect(read.outcome, ClaudeKeychainOutcome.refused);
      // The prefixes name `security` and the call that failed; only the tail
      // says anything the user can act on.
      expect(read.detail, 'User interaction is not allowed.');
      expect(read.secret, isNull);
    });

    test('an empty success is not a credential', () {
      // Otherwise the fetch sends `Bearer ` and reports an expired token.
      expect(
        claudeKeychainReadOf(0, stdout: '   ').outcome,
        ClaudeKeychainOutcome.notFound,
      );
    });
  });

  group('the Claude usage fetch on a Mac', () {
    late _FakeHttpClient http;

    AgentUsageService serviceWith(
      ClaudeKeychainCache keychain, {
      _FakeHttpClient? client,
    }) {
      http = client ?? _FakeHttpClient(200, _usageBody);
      return AgentUsageService(
        storeLocator: _FixedStores([
          const CliStore(
            environmentId: 'windows',
            homesByAgentId: {'claudeCode': '/Users/me/.claude'},
          ),
        ]),
        clock: FixedClock(testTime),
        httpClientFactory: () => http,
        keychain: keychain,
        // The branch under test only exists on macOS, and the suite also runs
        // on Windows: pinned, or this file would silently test nothing there.
        hostIsMacOS: true,
      );
    }

    test(
      'a refused Keychain says so, and asks nothing of the network',
      () async {
        final service = serviceWith(
          ClaudeKeychainCache(
            read: () async => const ClaudeKeychainRead(
              ClaudeKeychainOutcome.refused,
              detail: 'User interaction is not allowed.',
            ),
          ),
        );

        await expectLater(
          () => service.fetch(agentInstallation(), [posixEnv()]),
          throwsA(
            isA<UsageException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('Keychain'),
                contains('User interaction is not allowed.'),
                // The old sentence sent people to log in again over a credential
                // that was sitting right there.
                isNot(contains('Not signed in')),
              ),
            ),
          ),
        );
        expect(http.requests, 0, reason: 'there was no token to send');
      },
    );

    test('a Keychain with no such item is a signed-out user', () async {
      final service = serviceWith(
        ClaudeKeychainCache(
          read: () async => const ClaudeKeychainRead.notFound(),
        ),
      );

      await expectLater(
        () => service.fetch(agentInstallation(), [posixEnv()]),
        throwsA(
          isA<UsageException>().having(
            (e) => e.message,
            'message',
            contains('Not signed in'),
          ),
        ),
      );
    });

    test('a token the endpoint rejects is dropped, not held', () async {
      final security = _CountingKeychain(
        ClaudeKeychainRead(
          ClaudeKeychainOutcome.found,
          secret: _credentials('stale'),
        ),
      );
      final cache = ClaudeKeychainCache(read: security.read);
      final client = _FakeHttpClient(401, '{}');
      final service = serviceWith(cache, client: client);

      await expectLater(
        () => service.fetch(agentInstallation(), [posixEnv()]),
        throwsA(isA<UsageException>()),
      );

      // The CLI refreshes its own token; ours was rejected, so it is wrong
      // whatever the memo's clock says. Without this the chip would report
      // "access token expired" for the rest of the window, over a token the
      // Keychain had already replaced.
      security.answer = ClaudeKeychainRead(
        ClaudeKeychainOutcome.found,
        secret: _credentials('fresh'),
      );
      client.statusCode = 200;
      client.body = _usageBody;

      final usage = await service.fetch(agentInstallation(), [posixEnv()]);
      expect(usage.windows.single.percent, 42.0);
      expect(security.reads, 2);
      expect(client.sentAuthorization.last, 'Bearer fresh');
    });
  });
}
