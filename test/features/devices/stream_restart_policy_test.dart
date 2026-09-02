// The recovery ladder: which rung, and when.
//
// 1.6.0 had one rung — tear the session down and build a new one — and the
// owner asked the obvious question: "isn't there an automated way to recover it
// when the user starts interacting, without going through the destructive
// restart?" There is, and the cheap rungs must be tried first, each given a
// moment to work before the next is taken as necessary.
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/devices/application/stream_restart_policy.dart';
import 'package:karmashala/src/features/devices/data/device_stream.dart';

DeviceStreamHealth _health(DeviceStreamState state) =>
    DeviceStreamHealth(state: state, detail: '$state');

const _live = DeviceStreamState.live;
const _idle = DeviceStreamState.idle;
const _ended = DeviceStreamState.ended;
const _stalled = DeviceStreamState.stalled;

void main() {
  group('StreamRestartPolicy', () {
    final t0 = DateTime(2026, 9, 2, 16, 19, 44);

    test('an idle device is left alone', () {
      // The bug behind all of this: a phone showing a static screen is not
      // broken, and recovering it is how you make it look broken.
      final policy = StreamRestartPolicy();
      expect(policy.onHealth(_health(_idle), t0).action, StreamRecovery.none);
      expect(
        policy.onHealth(_health(_idle), t0.add(const Duration(minutes: 5)))
            .action,
        StreamRecovery.none,
      );
      expect(policy.attempt, 0);
    });

    test('a frozen picture asks the device for a keyframe first', () {
      // Nothing is torn down for this: no process, no forward, no socket, no
      // player. The user sees the picture resume.
      final policy = StreamRestartPolicy();
      final step = policy.onHealth(
        _health(_stalled),
        t0,
        canResetVideo: true,
      );
      expect(step.action, StreamRecovery.resetVideo);
      expect(step.delay, Duration.zero, reason: 'the cheap rungs do not wait');
      expect(policy.attempt, 0, reason: 'no restart has been spent');
    });

    test('the ladder climbs only when the rung below did not work', () {
      final policy = StreamRestartPolicy(
        stepGrace: const Duration(seconds: 2),
      );
      var now = t0;
      expect(
        policy.onHealth(_health(_stalled), now, canResetVideo: true).action,
        StreamRecovery.resetVideo,
      );
      // Still frozen two seconds later: the reset did not take.
      now = now.add(const Duration(seconds: 2));
      expect(
        policy.onHealth(_health(_stalled), now, canResetVideo: true).action,
        StreamRecovery.reattachPlayer,
      );
      // Still frozen: only now is the destructive step worth its cost.
      now = now.add(const Duration(seconds: 2));
      final restart = policy.onHealth(
        _health(_stalled),
        now,
        canResetVideo: true,
      );
      expect(restart.action, StreamRecovery.restart);
      expect(restart.delay, kStreamReconnectBackoff.first);
    });

    test('a rung is given its moment before the next one is taken', () {
      // The watchdog re-reports a fault every second. Without this the whole
      // ladder would be climbed in three ticks, and a video reset needs time
      // for the device to encode the keyframe it was asked for.
      final policy = StreamRestartPolicy(
        stepGrace: const Duration(seconds: 2),
      );
      expect(
        policy.onHealth(_health(_stalled), t0, canResetVideo: true).action,
        StreamRecovery.resetVideo,
      );
      expect(
        policy
            .onHealth(
              _health(_stalled),
              t0.add(const Duration(milliseconds: 900)),
              canResetVideo: true,
            )
            .action,
        StreamRecovery.none,
      );
    });

    test('without a control socket the cheapest rung does not exist', () {
      // A session that fell back to `adb shell input` has no control socket to
      // ask down, and asking is the only thing that rung does.
      final policy = StreamRestartPolicy();
      expect(
        policy.onHealth(_health(_stalled), t0).action,
        StreamRecovery.reattachPlayer,
      );
    });

    test('a connection that has ended can only be restarted', () {
      // Nothing downstream can be re-attached to a socket that closed, and
      // there is nobody left to ask for a keyframe.
      final policy = StreamRestartPolicy();
      final step = policy.onHealth(
        _health(_ended),
        t0,
        canResetVideo: true,
      );
      expect(step.action, StreamRecovery.restart);
      expect(step.delay, kStreamReconnectBackoff.first);
    });

    test('the backoff escalates across repeated failures', () {
      final policy = StreamRestartPolicy();
      var now = t0;
      for (final expected in kStreamReconnectBackoff) {
        final step = policy.onHealth(_health(_ended), now);
        expect(step.action, StreamRecovery.restart);
        expect(step.delay, expected);
        now = now.add(const Duration(seconds: 12));
        // Every restart works for a moment before failing again — which is
        // exactly what the flat eleven-second loop looked like.
        expect(policy.onHealth(_health(_live), now).action, StreamRecovery.none);
        now = now.add(const Duration(seconds: 2));
      }
      expect(policy.isExhausted, isTrue);
      expect(
        policy.onHealth(_health(_ended), now).action,
        StreamRecovery.none,
        reason: 'the user is told and given the button instead',
      );
    });

    test('a momentary recovery does not reset the escalation', () {
      final policy = StreamRestartPolicy();
      expect(
        policy.onHealth(_health(_ended), t0).delay,
        const Duration(seconds: 1),
      );
      expect(
        policy.onHealth(_health(_live), t0.add(const Duration(seconds: 5)))
            .action,
        StreamRecovery.none,
      );
      expect(
        policy.onHealth(_health(_ended), t0.add(const Duration(seconds: 11)))
            .delay,
        const Duration(seconds: 2),
        reason: 'six seconds of health is not a recovery',
      );
    });

    test('a stream that ran for a while starts the ladder over', () {
      final policy = StreamRestartPolicy(
        settleAfter: const Duration(seconds: 60),
      );
      expect(
        policy.onHealth(_health(_stalled), t0, canResetVideo: true).action,
        StreamRecovery.resetVideo,
      );
      expect(
        policy.onHealth(_health(_live), t0.add(const Duration(seconds: 5)))
            .action,
        StreamRecovery.none,
      );
      expect(
        policy
            .onHealth(
              _health(_stalled),
              t0.add(const Duration(minutes: 30)),
              canResetVideo: true,
            )
            .action,
        StreamRecovery.resetVideo,
        reason: 'half an hour later is a new incident, not the same one',
      );
    });

    test('idleness counts as the health that settles an incident', () {
      // A device nobody touches reports idle, not live, so treating idle as
      // anything less than healthy would leave the ladder half-climbed forever.
      final policy = StreamRestartPolicy(
        settleAfter: const Duration(seconds: 60),
      );
      expect(policy.onHealth(_health(_ended), t0).action, StreamRecovery.restart);
      expect(
        policy.onHealth(_health(_idle), t0.add(const Duration(seconds: 5)))
            .action,
        StreamRecovery.none,
      );
      expect(
        policy.onHealth(_health(_ended), t0.add(const Duration(minutes: 2)))
            .delay,
        kStreamReconnectBackoff.first,
      );
    });

    test('the restart the user asked for starts the ladder again', () {
      final policy = StreamRestartPolicy();
      policy.onHealth(_health(_ended), t0);
      policy.onHealth(_health(_ended), t0.add(const Duration(seconds: 30)));
      expect(policy.attempt, 2);
      policy.reset();
      expect(policy.attempt, 0);
      expect(
        policy.onHealth(_health(_stalled), t0, canResetVideo: true).action,
        StreamRecovery.resetVideo,
      );
    });
  });
}
