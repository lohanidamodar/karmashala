import 'package:chitragupta/src/features/terminal/application/scrollback_autosave.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ticks through the injected scheduler and stops cleanly', () {
    var ticks = 0;
    void Function()? pending;
    Object? cancelled;

    final autosave = ScrollbackAutosave(
      onTick: () => ticks++,
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

  test('start is idempotent, so it never leaks a second timer', () {
    var scheduled = 0;
    final autosave = ScrollbackAutosave(
      onTick: () {},
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
      onTick: () {},
      schedule: (duration, callback) => 1,
      cancel: (_) => cancelled++,
    );
    autosave.stop();
    expect(cancelled, 0);
  });

  test('it can be restarted after being stopped', () {
    var scheduled = 0;
    final autosave = ScrollbackAutosave(
      onTick: () {},
      schedule: (duration, callback) => ++scheduled,
      cancel: (_) {},
    );
    autosave
      ..start()
      ..stop()
      ..start();
    expect(scheduled, 2);
  });

  test('the default interval is the documented 20 seconds', () {
    expect(kScrollbackAutosaveInterval, const Duration(seconds: 20));
  });
}
