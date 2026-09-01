import 'package:karmashala/src/features/terminal/application/scrollback_autosave.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ticks through the injected scheduler and stops cleanly', () {
    var ticks = 0;
    void Function()? pending;
    Object? cancelled;

    final autosave = ScrollbackAutosave(
      onTick: () {
        ticks++;
        return false;
      },
      schedule: (duration, callback) {
        pending = callback;
        return 'handle';
      },
      cancel: (handle) => cancelled = handle,
    );

    autosave.start();
    pending!();
    pending!();
    expect(ticks, 2);

    autosave.stop();
    expect(cancelled, 'handle');
  });

  test('a tick that leaves a backlog comes back on the catch-up cadence', () {
    // The scale-target behaviour: with a hundred busy panes one capped batch
    // cannot save them all, so the autosave must drain rather than wait out a
    // full idle interval with the work still owed.
    final delays = <Duration>[];
    void Function()? pending;
    var backlog = true;

    final autosave = ScrollbackAutosave(
      onTick: () => backlog,
      schedule: (delay, callback) {
        delays.add(delay);
        pending = callback;
        return Object();
      },
      cancel: (_) {},
    )..start();

    expect(delays, [kScrollbackAutosaveInterval], reason: 'first tick is idle');

    pending!();
    pending!();
    expect(
      delays.sublist(1),
      [kScrollbackAutosaveCatchUp, kScrollbackAutosaveCatchUp],
      reason: 'while work remains',
    );

    backlog = false;
    pending!();
    expect(
      delays.last,
      kScrollbackAutosaveInterval,
      reason: 'back to idle once everything is saved',
    );
    autosave.stop();
  });

  group('catchUpSoon', () {
    /// Drives an autosave whose armed delays and cancels are recorded.
    ({
      ScrollbackAutosave autosave,
      List<Duration> delays,
      List<Object> cancels,
      void Function() Function() pending,
    })
    harness({required bool backlog}) {
      final delays = <Duration>[];
      final cancels = <Object>[];
      void Function()? pending;
      var handles = 0;
      final autosave = ScrollbackAutosave(
        onTick: () => backlog,
        schedule: (delay, callback) {
          delays.add(delay);
          pending = callback;
          return 'handle-${handles++}';
        },
        cancel: cancels.add,
      );
      return (
        autosave: autosave,
        delays: delays,
        cancels: cancels,
        pending: () => pending!,
      );
    }

    test('pulls an idle tick forward, cancelling the one it replaces', () {
      // Work that arrived between ticks: a structural workspace save writes the
      // tabs now and leaves the scrollback for the autosave, so waiting out a
      // full idle interval would sit on text already known to be owed.
      final h = harness(backlog: false);
      h.autosave.start();
      expect(h.delays, [kScrollbackAutosaveInterval]);

      h.autosave.catchUpSoon();

      expect(h.delays.last, kScrollbackAutosaveCatchUp);
      expect(h.cancels, ['handle-0'], reason: 'no timer is left running');
    });

    test('is a no-op while a catch-up tick is already armed', () {
      // Otherwise a user splitting panes in a row would keep pushing the tick
      // a second further out and the backlog would never drain.
      final h = harness(backlog: true);
      h.autosave.start();
      h.pending()();
      expect(h.delays.last, kScrollbackAutosaveCatchUp);

      h.autosave
        ..catchUpSoon()
        ..catchUpSoon();

      expect(h.delays, hasLength(2));
      expect(h.cancels, isEmpty);
    });

    test('does nothing when the autosave is not running', () {
      final h = harness(backlog: false);
      h.autosave.catchUpSoon();
      expect(h.delays, isEmpty);
      expect(h.cancels, isEmpty);
    });
  });

  test('a tick never overlaps itself', () {
    // Re-arming happens after onTick returns, so a batch that runs long cannot
    // have a second one scheduled on top of it.
    var scheduledDuringTick = 0;
    var scheduled = 0;
    void Function()? pending;
    late ScrollbackAutosave autosave;
    autosave = ScrollbackAutosave(
      onTick: () {
        scheduledDuringTick = scheduled;
        return false;
      },
      schedule: (delay, callback) {
        scheduled++;
        pending = callback;
        return Object();
      },
      cancel: (_) {},
    )..start();

    pending!();
    expect(scheduledDuringTick, 1, reason: 'nothing armed while ticking');
    expect(scheduled, 2, reason: 're-armed after');
    autosave.stop();
  });

  test('a stopped autosave does not re-arm from a tick already in flight', () {
    var scheduled = 0;
    void Function()? pending;
    late ScrollbackAutosave autosave;
    autosave = ScrollbackAutosave(
      onTick: () {
        autosave.stop();
        return true;
      },
      schedule: (delay, callback) {
        scheduled++;
        pending = callback;
        return Object();
      },
      cancel: (_) {},
    )..start();

    pending!();
    expect(scheduled, 1);
    expect(autosave.isRunning, isFalse);
  });

  test('start is idempotent, so it never leaks a second timer', () {
    var scheduled = 0;
    final autosave = ScrollbackAutosave(
      onTick: () => false,
      schedule: (duration, callback) => ++scheduled,
      cancel: (_) {},
    );

    autosave
      ..start()
      ..start();
    expect(scheduled, 1);
  });

  test('stopping before starting is harmless', () {
    var cancelled = 0;
    final autosave = ScrollbackAutosave(
      onTick: () => false,
      schedule: (duration, callback) => 1,
      cancel: (_) => cancelled++,
    );
    autosave.stop();
    expect(cancelled, 0);
  });

  test('it can be restarted after being stopped', () {
    var scheduled = 0;
    final autosave = ScrollbackAutosave(
      onTick: () => false,
      schedule: (duration, callback) => ++scheduled,
      cancel: (_) {},
    );
    autosave
      ..start()
      ..stop()
      ..start();
    expect(scheduled, 2);
  });

  test('the documented cadences and budget', () {
    expect(kScrollbackAutosaveInterval, const Duration(seconds: 20));
    expect(kScrollbackAutosaveCatchUp, const Duration(seconds: 1));
    // Half a 60 Hz frame: a tick may drop one, never freeze the app.
    expect(kScrollbackAutosaveBudget, const Duration(milliseconds: 8));
  });
}
