import 'package:karmashala_core/util.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// A clock a test moves by hand. Nothing here waits: the claim ages because the
/// test says it did, which is the only way to assert on a lapse without timing
/// anything.
class MovableClock implements Clock {
  MovableClock(this._now);
  DateTime _now;
  void advance(Duration by) => _now = _now.add(by);
  @override
  DateTime nowUtc() => _now.toUtc();
}

void main() {
  late MovableClock clock;

  /// Which sessions this app still knows, and what they are called. Removing
  /// one is what "that session is over" looks like to the registry.
  late Map<String, String> live;

  DeviceClaims claims({Duration? lapsesAfter}) => DeviceClaims(
    clock: clock,
    holder: (id) => live[id],
    lapsesAfter: lapsesAfter ?? kDeviceClaimLapse,
  );

  setUp(() {
    clock = MovableClock(testTime);
    live = {'s1': 'Fix the login flow', 's2': 'Check the release build'};
  });

  group('one task per device', () {
    test('two concurrent callers cannot both hold one device', () {
      final registry = claims();

      final first = registry.claim(
        deviceId: 'emulator-5554',
        sessionId: 's1',
        verb: 'device_tap',
      );
      expect(first!.holderSessionId, 's1');

      expect(
        () => registry.claim(
          deviceId: 'emulator-5554',
          sessionId: 's2',
          verb: 'device_tap',
        ),
        throwsA(isA<DeviceBusy>()),
      );

      // And the first caller still has it — a refused second attempt must not
      // leave the device in some third state where neither is driving.
      expect(registry.standing('emulator-5554')!.holderSessionId, 's1');
    });

    test('the refusal names the holder, not merely the device', () {
      final registry = claims();
      registry.claim(
        deviceId: 'emulator-5554',
        sessionId: 's1',
        verb: 'device_tap_element',
      );
      clock.advance(const Duration(seconds: 12));

      final busy = _busy(
        () => registry.claim(
          deviceId: 'emulator-5554',
          sessionId: 's2',
          verb: 'device_type',
        ),
      );

      // Who: by the name a reader would recognise *and* the id they can act on.
      expect(busy.message, contains('Fix the login flow'));
      expect(busy.message, contains('s1'));
      // Since when, and how stale — a reading carries its age (§19).
      expect(busy.message, contains('12s ago'));
      // What it was doing, so the reader can tell a drive from a stray tap.
      expect(busy.message, contains('device_tap_element'));
      // And the verb that was refused, so the sentence stands on its own.
      expect(busy.message, startsWith('device_type:'));
      // The claim itself travels with the refusal, for a caller that wants the
      // holder rather than the sentence.
      expect(busy.claim.holderSessionId, 's1');
    });

    test('the refusal says what will clear it, and that reading is not blocked', () {
      final registry = claims();
      registry.claim(
        deviceId: 'emulator-5554',
        sessionId: 's1',
        verb: 'device_tap',
      );

      final busy = _busy(
        () => registry.claim(
          deviceId: 'emulator-5554',
          sessionId: 's2',
          verb: 'device_tap',
        ),
      );

      expect(busy.message, contains('when that session ends'));
      expect(busy.message, contains('lapses on its own'));
      expect(busy.message, contains('device_ui_dump'));
    });

    test('different devices are driven in parallel', () {
      final registry = claims();
      registry.claim(
        deviceId: 'emulator-5554',
        sessionId: 's1',
        verb: 'device_tap',
      );
      expect(
        registry.claim(
          deviceId: 'emulator-5556',
          sessionId: 's2',
          verb: 'device_tap',
        )!.holderSessionId,
        's2',
      );
    });

    test('the holder is not refused its own device, and its run is counted', () {
      final registry = claims();
      registry.claim(
        deviceId: 'emulator-5554',
        sessionId: 's1',
        verb: 'device_tap',
      );
      final again = registry.claim(
        deviceId: 'emulator-5554',
        sessionId: 's1',
        verb: 'device_type',
      );
      expect(again!.calls, 2);
      expect(again.lastVerb, 'device_type');
      expect(again.takenAt, testTime, reason: 'one run, not two');
    });
  });

  group('a holder that goes away', () {
    test('a session that is over does not keep the device', () {
      final registry = claims();
      registry.claim(
        deviceId: 'emulator-5554',
        sessionId: 's1',
        verb: 'device_tap',
      );

      live.remove('s1');

      expect(registry.standing('emulator-5554'), isNull);
      expect(
        registry.claim(
          deviceId: 'emulator-5554',
          sessionId: 's2',
          verb: 'device_tap',
        )!.holderSessionId,
        's2',
      );
    });

    test('a claim lapses once its holder goes quiet', () {
      final registry = claims();
      registry.claim(
        deviceId: 'emulator-5554',
        sessionId: 's1',
        verb: 'device_tap',
      );

      clock.advance(kDeviceClaimLapse - const Duration(seconds: 1));
      expect(
        registry.standing('emulator-5554'),
        isNotNull,
        reason: 'a gap inside the window is an agent thinking, not a dead one',
      );

      clock.advance(const Duration(seconds: 1));
      expect(registry.standing('emulator-5554'), isNull);
      expect(
        registry.claim(
          deviceId: 'emulator-5554',
          sessionId: 's2',
          verb: 'device_tap',
        )!.holderSessionId,
        's2',
      );
    });

    test('a read by the holder is enough to keep the device', () {
      final registry = claims();
      registry.claim(
        deviceId: 'emulator-5554',
        sessionId: 's1',
        verb: 'device_tap',
      );

      // A drive is look-tap-look, so the looking counts.
      for (var i = 0; i < 4; i++) {
        clock.advance(const Duration(minutes: 1));
        registry.observed(deviceId: 'emulator-5554', sessionId: 's1');
      }
      expect(registry.standing('emulator-5554')!.holderSessionId, 's1');
    });

    test('release drops the device at once, without waiting out the lapse', () {
      final registry = claims();
      registry.claim(
        deviceId: 'emulator-5554',
        sessionId: 's1',
        verb: 'device_tap',
      );
      registry.claim(
        deviceId: 'emulator-5556',
        sessionId: 's1',
        verb: 'device_tap',
      );

      registry.release('s1');

      expect(registry.standingClaims, isEmpty);
    });
  });

  group('reading is never a claim', () {
    test('a read takes no device', () {
      final registry = claims();
      registry.observed(deviceId: 'emulator-5554', sessionId: 's1');
      expect(registry.standing('emulator-5554'), isNull);
      expect(
        registry.claim(
          deviceId: 'emulator-5554',
          sessionId: 's2',
          verb: 'device_tap',
        )!.holderSessionId,
        's2',
      );
    });

    test('a stranger reading does not renew the holder', () {
      final registry = claims();
      registry.claim(
        deviceId: 'emulator-5554',
        sessionId: 's1',
        verb: 'device_tap',
      );

      clock.advance(kDeviceClaimLapse - const Duration(seconds: 1));
      registry.observed(deviceId: 'emulator-5554', sessionId: 's2');
      clock.advance(const Duration(seconds: 1));

      expect(
        registry.standing('emulator-5554'),
        isNull,
        reason: 'somebody else watching is not the holder still working',
      );
    });
  });

  group('an unattributed caller', () {
    test('respects a claim: there is no side door around a holder', () {
      final registry = claims();
      registry.claim(
        deviceId: 'emulator-5554',
        sessionId: 's1',
        verb: 'device_tap',
      );
      expect(
        () => registry.claim(
          deviceId: 'emulator-5554',
          sessionId: null,
          verb: 'device_tap',
        ),
        throwsA(isA<DeviceBusy>()),
      );
    });

    test('never takes one, because a holder we cannot name is the failure', () {
      final registry = claims();
      expect(
        registry.claim(
          deviceId: 'emulator-5554',
          sessionId: null,
          verb: 'device_tap',
        ),
        isNull,
      );
      expect(registry.standing('emulator-5554'), isNull);
    });
  });

  group('a holder renamed mid-drive', () {
    test('is refused under the name the reader would recognise now', () {
      final registry = claims();
      registry.claim(
        deviceId: 'emulator-5554',
        sessionId: 's1',
        verb: 'device_tap',
      );
      live['s1'] = 'Reproduce the crash';

      final busy = _busy(
        () => registry.claim(
          deviceId: 'emulator-5554',
          sessionId: 's2',
          verb: 'device_tap',
        ),
      );
      expect(busy.message, contains('Reproduce the crash'));
      expect(busy.message, isNot(contains('Fix the login flow')));
    });
  });

  group('describeDriveAge', () {
    test('says seconds, which describeAge deliberately does not', () {
      expect(describeDriveAge(const Duration(seconds: 0)), 'just now');
      expect(describeDriveAge(const Duration(seconds: 12)), '12s ago');
      expect(describeDriveAge(const Duration(seconds: 59)), '59s ago');
      expect(describeDriveAge(const Duration(minutes: 3)), '3m ago');
      expect(describeDriveAge(const Duration(hours: 2)), '2h ago');
    });
  });
}

/// The [DeviceBusy] [act] throws, so a test can assert on the sentence.
DeviceBusy _busy(void Function() act) {
  try {
    act();
  } on DeviceBusy catch (busy) {
    return busy;
  }
  fail('expected the device to be refused');
}
