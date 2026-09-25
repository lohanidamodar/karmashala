import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:test/test.dart';

final _at = DateTime.utc(2026, 9, 25);

SessionFacts _facts(HostSessionState state, {int? exitCode, String? reason}) =>
    SessionFacts(
      hostSessionId: 'karmashala_s1',
      state: state,
      exitCode: exitCode,
      reason: reason,
      observedAt: _at,
    );

void main() {
  group('the status table', () {
    test('no host knows the session: unknown', () {
      expect(lifecycleStatusFrom(null), SessionStatus.unknown);
    });

    test('running while the process runs', () {
      expect(
        lifecycleStatusFrom(_facts(HostSessionState.running)),
        SessionStatus.running,
      );
    });

    test('exited with code 0: completed', () {
      expect(
        lifecycleStatusFrom(_facts(HostSessionState.exited, exitCode: 0)),
        SessionStatus.completed,
      );
    });

    test('exited with a non-zero code: failed', () {
      for (final code in [1, 2, 130, 143, -1]) {
        expect(
          lifecycleStatusFrom(_facts(HostSessionState.exited, exitCode: code)),
          SessionStatus.failed,
          reason: 'code $code',
        );
      }
    });

    test('exited with no code is unknown, never a success', () {
      expect(
        lifecycleStatusFrom(
          _facts(HostSessionState.exited, reason: 'host stopped while running'),
        ),
        SessionStatus.unknown,
      );
    });

    test(
      'closed, and the close ended it: cancelled, whatever code it left',
      () {
        SessionFacts closed({int? exitCode}) => SessionFacts(
          hostSessionId: 'h',
          state: HostSessionState.closed,
          observedAt: DateTime.utc(2026),
          exitCode: exitCode,
          endedByClose: true,
        );
        expect(lifecycleStatusFrom(closed()), SessionStatus.cancelled);
        expect(
          lifecycleStatusFrom(closed(exitCode: 0)),
          SessionStatus.cancelled,
        );
      },
    );

    // Found live: an automation's session ended by `session_end` read
    // `failed` on its `exited` (the signal's 143) before `closed` said
    // cancelled, and the run settled on the first.
    test('exited because a close asked it to: cancelled, never failed', () {
      SessionFacts exited({int? exitCode}) => SessionFacts(
        hostSessionId: 'h',
        state: HostSessionState.exited,
        observedAt: DateTime.utc(2026),
        exitCode: exitCode,
        reason: 'exited',
        endedByClose: true,
      );
      for (final code in [143, 137, 1, 0, null]) {
        expect(
          lifecycleStatusFrom(exited(exitCode: code)),
          SessionStatus.cancelled,
          reason: 'code $code',
        );
      }
    });

    test('an exit nobody asked for keeps its own status', () {
      SessionFacts crashed(int? exitCode) => SessionFacts(
        hostSessionId: 'h',
        state: HostSessionState.exited,
        observedAt: DateTime.utc(2026),
        exitCode: exitCode,
      );
      expect(lifecycleStatusFrom(crashed(143)), SessionStatus.failed);
      expect(lifecycleStatusFrom(crashed(139)), SessionStatus.failed);
      expect(lifecycleStatusFrom(crashed(null)), SessionStatus.unknown);
      expect(lifecycleStatusFrom(crashed(0)), SessionStatus.completed);
    });

    // Found running the app: after a host crash the pane lets go of the dead
    // session's record, and that close read as the person stopping it.
    test('closed after it had already ended: what its exit says', () {
      SessionFacts released({int? exitCode}) => SessionFacts(
        hostSessionId: 'h',
        state: HostSessionState.closed,
        observedAt: DateTime.utc(2026),
        exitCode: exitCode,
        reason: 'host stopped while running',
      );
      expect(lifecycleStatusFrom(released()), SessionStatus.unknown);
      expect(
        lifecycleStatusFrom(released(exitCode: 0)),
        SessionStatus.completed,
      );
      expect(lifecycleStatusFrom(released(exitCode: 2)), SessionStatus.failed);
    });
  });

  group('a lifecycle event', () {
    test('leaves the session in the state its kind names', () {
      SessionFacts of(SessionLifecycleKind kind) => SessionLifecycleEvent(
        hostSessionId: 'h',
        kind: kind,
        observedAt: _at,
        exitCode: 3,
        reason: 'r',
      ).facts;
      expect(of(SessionLifecycleKind.started).state, HostSessionState.running);
      expect(of(SessionLifecycleKind.exited).state, HostSessionState.exited);
      expect(of(SessionLifecycleKind.closed).state, HostSessionState.closed);
      expect(of(SessionLifecycleKind.exited).exitCode, 3);
      expect(of(SessionLifecycleKind.exited).reason, 'r');
      expect(of(SessionLifecycleKind.exited).observedAt, _at);
    });
  });

  group('host session ids', () {
    test('are the session id behind karmashala_', () {
      expect(hostSessionIdOf('abc-123_X'), 'karmashala_abc-123_X');
    });

    test('replace every character outside [a-zA-Z0-9_-] with _', () {
      expect(hostSessionIdOf('a.b:c/d eé'), 'karmashala_a_b_c_d_e_');
    });

    test('find the candidate a host id belongs to', () {
      const candidates = ['s1', 'a.b', 'other'];
      expect(sessionIdForHostId('karmashala_s1', candidates), 's1');
      expect(sessionIdForHostId('karmashala_a_b', candidates), 'a.b');
      expect(sessionIdForHostId('karmashala_nope', candidates), isNull);
    });

    test('a pane-only host session belongs to no session', () {
      expect(
        sessionIdForHostId('karmashala_local_p1', ['p1', 'local']),
        isNull,
      );
    });

    test('when sanitising collides, the first candidate wins', () {
      expect(sessionIdForHostId('karmashala_a_b', ['a:b', 'a.b']), 'a:b');
    });
  });
}
