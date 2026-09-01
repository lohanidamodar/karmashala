import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/features/devices/data/idb_service.dart';
import 'package:karmashala/src/features/devices/domain/device_action.dart';
import 'package:karmashala/src/features/devices/domain/device_input.dart';

import '../../support/fake_command_runner.dart';

const _installed = IdbInstallation(executable: '/opt/homebrew/bin/idb');

IdbService _service(FakeCommandRunner runner) =>
    IdbService(runner: runner, installation: _installed);

FakeCommandRunner _ok([String stdout = '']) => FakeCommandRunner(
  responder: (_) => CommandResult(exitCode: 0, stdout: stdout, stderr: ''),
);

void main() {
  group('discovery', () {
    test('asks a login shell, because pip and brew are not on a bare PATH', () {
      // The same reason agent CLIs are looked up that way: a non-login shell's
      // PATH does not have ~/.local/bin or Homebrew, so a bare `which` reports
      // "not installed" for an idb that works in the user's terminal.
      final runner = _ok('/opt/homebrew/bin/idb\n');

      return IdbService.discover(runner: runner, loginShell: '/bin/zsh').then((
        found,
      ) {
        expect(found, isNotNull);
        expect(found!.executable, '/opt/homebrew/bin/idb');
        expect(runner.requests.first.executable, '/bin/zsh');
        expect(runner.requests.first.arguments, [
          '-lc',
          'command -v idb',
        ]);
      });
    });

    test('a machine without idb gets null, not an exception', () async {
      // Everything idb provides is *absent* there, not broken: the pane still
      // lists simulators, boots them and shows logs.
      expect(
        await IdbService.discover(
          runner: FakeCommandRunner(
            responder: (_) =>
                const CommandResult(exitCode: 1, stdout: '', stderr: ''),
          ),
          loginShell: '/bin/zsh',
        ),
        isNull,
      );
      expect(
        await IdbService.discover(
          runner: FakeCommandRunner(throwError: CommandException('no shell')),
          loginShell: '/bin/zsh',
        ),
        isNull,
      );
      expect(
        await IdbService.discover(
          runner: _ok('   \n'),
          loginShell: '/bin/zsh',
        ),
        isNull,
        reason: 'a blank answer located nothing',
      );
    });

    test('an idb that will not say its version is still usable', () async {
      var call = 0;
      final runner = FakeCommandRunner(
        responder: (_) => call++ == 0
            ? const CommandResult(exitCode: 0, stdout: '/bin/idb', stderr: '')
            : const CommandResult(exitCode: 1, stdout: '', stderr: 'boom'),
      );

      final found = await IdbService.discover(
        runner: runner,
        loginShell: '/bin/bash',
      );

      expect(found!.executable, '/bin/idb');
      expect(found.version, isNull);
    });
  });

  group('input', () {
    test('every command names the device it is for', () async {
      // idb addresses a target by udid; without it a command lands on whichever
      // target the companion happens to hold.
      final runner = _ok();
      await _service(runner).tap('UDID-1', 10, 20);

      expect(runner.requests.single.executable, '/opt/homebrew/bin/idb');
      expect(runner.requests.single.arguments, [
        'ui', 'tap', '10', '20', '--udid', 'UDID-1',
      ]);
    });

    test('swipe, with and without a duration', () async {
      final runner = _ok();
      final idb = _service(runner);

      await idb.swipe('U', fromX: 1, fromY: 2, toX: 3, toY: 4);
      await idb.swipe(
        'U',
        fromX: 1,
        fromY: 2,
        toX: 3,
        toY: 4,
        duration: const Duration(milliseconds: 750),
      );

      expect(runner.requests.first.arguments, [
        'ui', 'swipe', '1', '2', '3', '4', '--udid', 'U',
      ]);
      expect(runner.requests.last.arguments, [
        'ui', 'swipe', '1', '2', '3', '4', '--duration', '0.750', '--udid', 'U',
      ]);
    });

    test('text travels as one argument, so nothing needs escaping', () async {
      // `adb shell input text` pastes into a shell command line and has to
      // escape metacharacters and turn spaces into %s. idb does not.
      final runner = _ok();

      await _service(runner).inputText('U', r'a b & c $d "e"');

      expect(runner.requests.single.arguments, [
        'ui', 'text', r'a b & c $d "e"', '--udid', 'U',
      ]);
    });

    test('the buttons iOS actually has', () async {
      final runner = _ok();
      await _service(runner).pressButton('U', IdbButton.home);

      expect(runner.requests.single.arguments, [
        'ui', 'button', 'HOME', '--udid', 'U',
      ]);
    });

    test('Android navigation keys have no iOS equivalent, and say so', () {
      // Pressing a best-effort substitute would silently do the wrong thing:
      // iOS has no system back button — an app draws its own — and no recents.
      expect(IdbButton.forKey(DeviceKey.home), IdbButton.home);
      expect(IdbButton.forKey(DeviceKey.power), IdbButton.lock);
      expect(IdbButton.forKey(DeviceKey.back), isNull);
      expect(IdbButton.forKey(DeviceKey.recents), isNull);
    });
  });

  group('reading the screen', () {
    test('asks for the complete format and the in-simulator reader', () async {
      // `complete` carries the screen bounds the frames are relative to, which
      // is the only trustworthy source for the point-space size a tap needs.
      // `axbridge-persistent` reads from inside the simulator, so a composed
      // view reports as the elements the app built rather than one opaque box,
      // and the warm reader takes a read from ~3.5s to ~0.2s.
      final runner = _ok(
        '{"elements": [], "screen": {"width": 402, "height": 874}}',
      );

      final read = await _service(runner).describeAll('U');

      expect(runner.requests.single.arguments, [
        'ui', 'describe-all',
        '--format', 'complete',
        '--api', 'axbridge-persistent',
        '--udid', 'U',
      ]);
      expect(read.screen, const DeviceScreenSize(width: 402, height: 874));
    });

    test('the cheap host-side read can be asked for instead', () async {
      final runner = _ok('[]');
      await _service(runner).describeAll('U', detailed: false);

      expect(runner.requests.single.arguments, [
        'ui', 'describe-all', '--format', 'complete', '--udid', 'U',
      ]);
    });
  });

  group('video', () {
    test('streams Annex-B H.264, which is what TsMuxer already eats', () async {
      // The same shape scrcpy produces, so everything downstream of the frame
      // reader is shared with the Android live view.
      final runner = _ok();

      await _service(runner).videoStream('U', fps: 60, scaleFactor: 0.5);

      expect(runner.startRequests.single.arguments, [
        'video-stream',
        '--format', 'h264',
        '--fps', '60',
        '--compression-quality', '1.00',
        '--scale-factor', '0.50',
        '--udid', 'U',
      ]);
      expect(
        runner.requests,
        isEmpty,
        reason: 'a live stream is started, not run to completion',
      );
    });
  });

  group('failure and recording', () {
    test('a failure is raised with what idb said, not just a code', () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'target UDID not found',
        ),
      );

      await expectLater(
        _service(runner).tap('U', 1, 2),
        throwsA(
          isA<CommandException>().having(
            (e) => e.message,
            'message',
            contains('target UDID not found'),
          ),
        ),
      );
    });

    test('actions reach the recorder, failures included', () async {
      final recorded = <DeviceAction>[];
      var fail = false;
      final runner = FakeCommandRunner(
        responder: (_) => fail
            ? const CommandResult(exitCode: 1, stdout: '', stderr: 'nope')
            : const CommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      final idb = _service(runner)..actionSink = recorded.add;

      await idb.tap('U', 5, 6);
      fail = true;
      try {
        await idb.inputText('U', 'hi');
      } on CommandException {
        // The point of the case: a refusal is still recorded.
      }

      expect(recorded.map((a) => a.verb), ['tap', 'type']);
      expect(recorded.first.summary, 'tap (5, 6)');
      expect(recorded.first.ok, isTrue);
      expect(recorded.last.ok, isFalse);
      expect(recorded.last.detail, 'nope');
    });
  });
}
