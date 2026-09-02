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
      // The bug, in one line: a phone showing a static screen is not broken,
      // and restarting its stream is how you make it look broken.
      final policy = StreamRestartPolicy();
      expect(policy.onHealth(_health(_idle), t0), isNull);
      expect(
        policy.onHealth(
          _health(_idle),
          t0.add(const Duration(minutes: 5)),
        ),
        isNull,
      );
      expect(policy.attempt, 0);
      expect(policy.isExhausted, isFalse);
    });

    test('a dead stream is restarted', () {
      final policy = StreamRestartPolicy();
      expect(policy.onHealth(_health(_ended), t0), kStreamReconnectBackoff.first);
    });

    test('bytes that decode into nothing are restarted too', () {
      expect(
        StreamRestartPolicy().onHealth(_health(_stalled), t0),
        kStreamReconnectBackoff.first,
      );
    });

    test('the backoff escalates across repeated failures', () {
      final policy = StreamRestartPolicy();
      var now = t0;
      for (final expected in kStreamReconnectBackoff) {
        expect(policy.onHealth(_health(_ended), now), expected);
        now = now.add(const Duration(seconds: 12));
        // Every restart works for a moment before failing again — which is
        // exactly what the flat eleven-second loop looked like.
        expect(policy.onHealth(_health(_live), now), isNull);
        now = now.add(const Duration(seconds: 2));
      }
      expect(policy.isExhausted, isTrue);
      expect(
        policy.onHealth(_health(_ended), now),
        isNull,
        reason: 'the user is told and given the button instead',
      );
    });

    test('a momentary recovery does not reset the escalation', () {
      final policy = StreamRestartPolicy();
      expect(policy.onHealth(_health(_ended), t0), const Duration(seconds: 1));
      expect(
        policy.onHealth(_health(_live), t0.add(const Duration(seconds: 5))),
        isNull,
      );
      expect(
        policy.onHealth(_health(_ended), t0.add(const Duration(seconds: 11))),
        const Duration(seconds: 2),
        reason: 'six seconds of health is not a recovery',
      );
    });

    test('a stream that ran for a while starts the count over', () {
      final policy = StreamRestartPolicy(
        settleAfter: const Duration(seconds: 60),
      );
      expect(policy.onHealth(_health(_ended), t0), const Duration(seconds: 1));
      expect(
        policy.onHealth(_health(_live), t0.add(const Duration(seconds: 5))),
        isNull,
      );
      expect(
        policy.onHealth(
          _health(_ended),
          t0.add(const Duration(minutes: 30)),
        ),
        const Duration(seconds: 1),
        reason: 'half an hour later is a new fault, not the same one',
      );
    });

    test('idleness counts as the health that settles an incident', () {
      // A device nobody touches reports idle, not live, so treating idle as
      // anything less than healthy would leave the escalation armed forever.
      final policy = StreamRestartPolicy(
        settleAfter: const Duration(seconds: 60),
      );
      expect(policy.onHealth(_health(_ended), t0), const Duration(seconds: 1));
      expect(
        policy.onHealth(_health(_idle), t0.add(const Duration(seconds: 5))),
        isNull,
      );
      expect(
        policy.onHealth(_health(_ended), t0.add(const Duration(minutes: 2))),
        const Duration(seconds: 1),
      );
    });

    test('the restart the user asked for starts the count again', () {
      final policy = StreamRestartPolicy();
      policy.onHealth(_health(_ended), t0);
      policy.onHealth(_health(_ended), t0);
      expect(policy.attempt, 2);
      policy.reset();
      expect(policy.attempt, 0);
      expect(policy.onHealth(_health(_ended), t0), const Duration(seconds: 1));
    });
  });
}
