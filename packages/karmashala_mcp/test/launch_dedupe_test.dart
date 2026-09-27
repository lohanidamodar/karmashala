import 'dart:async';

import 'package:karmashala_core/util.dart';
import 'package:karmashala_mcp/launch.dart';
import 'package:test/test.dart';

/// Moved from the app's `test/features/mcp/launch_dedupe_test.dart` (slice
/// 5b): the ledger is the server's now — `open_new_session`, handoffs and
/// forks collapse a retried call onto the launch already made.
final testTime = DateTime.utc(2026, 9, 27, 12);

/// A clock the test moves, because the whole question the window answers is
/// "how long ago was this asked".
class _MovingClock implements Clock {
  DateTime now = testTime;
  @override
  DateTime nowUtc() => now;
}


void main() {
  group('which tools a retry must not repeat', () {
    test('the three that start an agent, and no others', () {
      for (final tool in [
        'open_new_session',
        'session_handoff',
        'session_fork',
      ]) {
        expect(startsAnAgent(tool, const {}), isTrue, reason: tool);
      }
      for (final tool in [
        'list_sessions',
        'list_projects',
        'open_session',
        'session_send',
        'note_add',
      ]) {
        expect(startsAnAgent(tool, const {}), isFalse, reason: tool);
      }
    });

    test('a preview starts nothing, so it is not one', () {
      expect(startsAnAgent('session_handoff', {'preview': true}), isFalse);
      expect(startsAnAgent('session_fork', {'preview': true}), isFalse);
      expect(startsAnAgent('session_fork', {'preview': false}), isTrue);
    });
  });

  group('the fingerprint', () {
    test('is the whole request, not a chosen few fields', () {
      final base = {'projectId': 'p1', 'prompt': 'audit', 'title': 't'};
      final key = launchFingerprint('open_new_session', base, 'caller-1');
      // Every one of these is a different request.
      expect(
        launchFingerprint('open_new_session', base, 'caller-2'),
        isNot(key),
      );
      expect(launchFingerprint('session_fork', base, 'caller-1'), isNot(key));
      expect(
        launchFingerprint('open_new_session', {
          ...base,
          'prompt': 'audit ',
        }, 'caller-1'),
        isNot(key),
      );
      expect(
        launchFingerprint('open_new_session', {
          ...base,
          'useWorktree': true,
        }, 'caller-1'),
        isNot(key),
      );
    });

    test('does not depend on the order the arguments arrived in', () {
      expect(
        launchFingerprint('open_new_session', {
          'projectId': 'p1',
          'prompt': 'audit',
        }, null),
        launchFingerprint('open_new_session', {
          'prompt': 'audit',
          'projectId': 'p1',
        }, null),
      );
    });

    test('reaches into nested values', () {
      expect(
        launchFingerprint('session_handoff', {
          'unresolved': ['a', 'b'],
        }, null),
        isNot(
          launchFingerprint('session_handoff', {
            'unresolved': ['b', 'a'],
          }, null),
        ),
      );
    });
  });

  group('the ledger', () {
    late _MovingClock clock;
    late LaunchDedupe dedupe;
    late List<String> collapsed;

    setUp(() async {
      clock = _MovingClock();
      collapsed = [];
      dedupe = LaunchDedupe(clock: clock, onCollapsed: collapsed.add);
    });

    Future<Object?> open(
      Future<Object?> Function() start, {
      String prompt = 'audit',
      String? caller = 'caller-1',
    }) => dedupe.run(
      tool: 'open_new_session',
      arguments: {'projectId': 'p1', 'prompt': prompt},
      callerSessionId: caller,
      start: start,
    );

    test('a repeat that arrives mid-flight gets the first call, not a '
        'second launch', () async {
      // The incident: the retry landed 55s in, while the first launch was still
      // making its worktree, so nothing had been *recorded* yet.
      final gate = Completer<Object?>();
      var launches = 0;
      Future<Object?> launch() {
        launches++;
        return gate.future;
      }

      final first = open(launch);
      final retry = open(launch);
      expect(launches, 1);

      gate.complete({'sessionId': '8a8ef8ed'});
      expect(await first, {'sessionId': '8a8ef8ed'});
      expect(await retry, {'sessionId': '8a8ef8ed'});
      expect(launches, 1);
      expect(collapsed, ['open_new_session']);
    });

    test('a repeat inside the window gets the session already open', () async {
      var launches = 0;
      Future<Object?> launch() async => {'sessionId': 's${++launches}'};

      expect(await open(launch), {'sessionId': 's1'});
      clock.now = clock.now.add(const Duration(seconds: 90));
      expect(await open(launch), {'sessionId': 's1'});
      expect(launches, 1);
    });

    test('past the window it is a new request again', () async {
      var launches = 0;
      Future<Object?> launch() async => {'sessionId': 's${++launches}'};

      expect(await open(launch), {'sessionId': 's1'});
      clock.now = clock.now.add(
        launchDedupeWindow + const Duration(seconds: 1),
      );
      expect(await open(launch), {'sessionId': 's2'});
      expect(launches, 2);
    });

    test('the window runs from when the launch finished, not when it '
        'started', () async {
      var launches = 0;
      final gate = Completer<Object?>();
      Future<Object?> launch() {
        launches++;
        return gate.future;
      }

      final first = open(launch);
      // A launch slower than the whole window is still one launch.
      clock.now = clock.now.add(const Duration(minutes: 5));
      gate.complete({'sessionId': 's1'});
      await first;

      clock.now = clock.now.add(const Duration(seconds: 30));
      expect(await open(launch), {'sessionId': 's1'});
      expect(launches, 1);
    });

    test('a different caller, or a different prompt, is a different '
        'request', () async {
      var launches = 0;
      Future<Object?> launch() async => {'sessionId': 's${++launches}'};

      expect(await open(launch), {'sessionId': 's1'});
      expect(await open(launch, caller: 'caller-2'), {'sessionId': 's2'});
      expect(await open(launch, prompt: 'something else'), {'sessionId': 's3'});
      expect(collapsed, isEmpty);
    });

    test('a failure is shared while in flight and forgotten after', () async {
      var launches = 0;
      final gate = Completer<Object?>();
      Future<Object?> launch() {
        launches++;
        return gate.future;
      }

      final first = open(launch);
      final retry = open(launch);
      gate.completeError(StateError('no agent is installed'));
      await expectLater(first, throwsStateError);
      await expectLater(retry, throwsStateError);
      expect(launches, 1);

      // Nothing survived that launch, so the next call must genuinely try
      // again rather than be handed two minutes of the same wrong answer.
      expect(await open(() async => {'sessionId': 's1'}), {'sessionId': 's1'});
    });
  });
}
