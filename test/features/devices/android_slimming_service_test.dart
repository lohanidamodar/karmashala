import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/features/devices/data/android_slimming_service.dart';
import 'package:karmashala/src/features/devices/domain/android_device.dart';
import 'package:karmashala/src/features/devices/domain/android_slimming.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';

import '../../support/fake_command_runner.dart';

const _adbPath = r'C:\sdk\platform-tools\adb.exe';

AndroidSdk _sdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(environmentId: 'windows', path: _adbPath),
);

AndroidSlimmingService _service(FakeCommandRunner runner) =>
    AndroidSlimmingService(
      runner: runner,
      sdk: _sdk(),
      pollInterval: Duration.zero,
      bootTimeout: Duration.zero,
    );

/// Every argv the runner saw, with the `-s <serial>` prefix stripped — that
/// part is asserted once and is noise in the rest.
List<List<String>> _commands(FakeCommandRunner runner) => [
  for (final request in runner.requests) request.arguments.sublist(2),
];

CommandResult _ok([String stdout = '']) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');

/// A runner that answers `getprop sys.boot_completed` with 1 and everything
/// else with success, unless [fail] claims the command.
FakeCommandRunner _booted({
  String? Function(CommandRequest request)? fail,
  String disabledList = '',
}) => FakeCommandRunner(
  responder: (request) {
    final argv = request.arguments.join(' ');
    if (argv.contains('sys.boot_completed')) return _ok('1\n');
    if (argv.contains('pm list packages')) return _ok(disabledList);
    final reason = fail?.call(request);
    if (reason != null) {
      return CommandResult(exitCode: 255, stdout: '', stderr: reason);
    }
    return _ok();
  },
);

void main() {
  group('parseDisabledPackages', () {
    test('reads the package: lines and ignores anything else', () {
      expect(
        parseDisabledPackages(
          'package:com.google.android.gms\r\n'
          'Exception occurred while executing\r\n'
          'package:com.android.vending\r\n',
        ),
        {'com.google.android.gms', 'com.android.vending'},
      );
    });

    test('is empty rather than wrong on empty output', () {
      expect(parseDisabledPackages(''), isEmpty);
      expect(parseDisabledPackages('package:'), isEmpty);
    });
  });

  group('apply', () {
    test('waits for the boot, then writes settings and disables packages in a '
        'stable order', () async {
      final runner = _booted();
      final report = await _service(runner).apply(
        'emulator-5554',
        enabled: {
          AndroidSlimmingCategory.animations,
          AndroidSlimmingCategory.media,
        },
      );

      expect(runner.requests.first.executable, _adbPath);
      expect(runner.requests.first.arguments.take(2), ['-s', 'emulator-5554']);
      expect(_commands(runner).first, [
        'shell',
        'getprop',
        'sys.boot_completed',
      ]);
      expect(_commands(runner).sublist(1), [
        ['shell', 'settings', 'put', 'global', 'window_animation_scale', '0'],
        [
          'shell',
          'settings',
          'put',
          'global',
          'transition_animation_scale',
          '0',
        ],
        ['shell', 'settings', 'put', 'global', 'animator_duration_scale', '0'],
        [
          'shell',
          'pm',
          'disable-user',
          '--user',
          '0',
          'com.google.android.apps.photos',
        ],
        [
          'shell',
          'pm',
          'disable-user',
          '--user',
          '0',
          'com.google.android.apps.youtube.music',
        ],
        [
          'shell',
          'pm',
          'disable-user',
          '--user',
          '0',
          'com.google.android.youtube',
        ],
      ]);
      expect(report.ok, isTrue);
      expect(report.applied, hasLength(6));
    });

    test('a refused step costs only itself', () async {
      // Observed for real: `pm disable-user` on a package the system image does
      // not carry exits 255 with `Unknown package: ...`. The other two package
      // groups on the same run have nothing to do with it.
      final runner = _booted(
        fail: (request) => request.arguments.contains('animator_duration_scale')
            ? 'Bad value'
            : null,
      );
      final report = await _service(
        runner,
      ).apply('emulator-5554', enabled: {AndroidSlimmingCategory.animations});

      expect(report.ok, isFalse);
      expect(report.failed, {'animator_duration_scale': 'Bad value'});
      expect(report.applied, [
        'window_animation_scale',
        'transition_animation_scale',
      ]);
      // Four commands: the boot check and all three settings, the failing one
      // included. Nothing was skipped because of it.
      expect(runner.requests, hasLength(4));
    });

    test('an adb that will not run is reported, never thrown', () async {
      final runner = FakeCommandRunner(
        throwError: CommandException('adb.exe is missing'),
      );
      final report = await _service(
        runner,
      ).apply('emulator-5554', enabled: {AndroidSlimmingCategory.animations});

      // The boot poll cannot answer either, so nothing is attempted at all —
      // and it is a report, not an exception, because the caller is a boot.
      expect(report.ok, isFalse);
      expect(report.failed.keys, ['emulator-5554']);
      expect(report.failed.values.single, contains('sys.boot_completed'));
    });

    test('a device that never finishes booting changes nothing', () async {
      // The alternative is sleeping and hoping, which lands `settings put` on a
      // half-booted system and fails in ways that look like our bug.
      final runner = FakeCommandRunner(responder: (_) => _ok('0\n'));
      final report = await _service(
        runner,
      ).apply('emulator-5554', enabled: {AndroidSlimmingCategory.playServices});

      expect(report.failed.keys, ['emulator-5554']);
      expect(
        _commands(runner).every((c) => c.contains('getprop')),
        isTrue,
        reason: 'nothing but the boot check was run',
      );
    });

    test('an empty selection does not even look at the device', () async {
      final runner = _booted();
      final report = await _service(runner).apply('emulator-5554');
      expect(report.isEmpty, isTrue);
      expect(runner.requests, isEmpty);
    });

    test('the launch-flag categories are not this class\'s business', () async {
      // They are argv for `emulator`, decided before there is a device to talk
      // to. Selecting one alone must not produce a single adb call.
      final runner = _booted();
      await _service(
        runner,
      ).apply('emulator-5554', enabled: {AndroidSlimmingCategory.audio});
      expect(runner.requests, isEmpty);
    });
  });

  group('restore', () {
    test('deletes every managed setting and re-enables only our packages', () async {
      // `com.android.nfc` was disabled by something else on the emulator this
      // was measured on. Re-enabling it would be undoing a decision that was
      // not ours.
      final runner = _booted(
        disabledList:
            'package:com.google.android.gms\n'
            'package:com.android.nfc\n',
      );
      final report = await _service(runner).restore('emulator-5554');

      final commands = _commands(runner);
      expect(commands.take(3), [
        ['shell', 'settings', 'delete', 'global', 'window_animation_scale'],
        ['shell', 'settings', 'delete', 'global', 'transition_animation_scale'],
        ['shell', 'settings', 'delete', 'global', 'animator_duration_scale'],
      ]);
      expect(commands.last, [
        'shell',
        'pm',
        'enable',
        '--user',
        '0',
        'com.google.android.gms',
      ]);
      expect(
        commands.any((c) => c.contains('com.android.nfc')),
        isFalse,
        reason: 'a package this build did not disable is left alone',
      );
      expect(report.ok, isTrue);
    });

    test('an emulator that was never slimmed is left as it is', () async {
      final runner = _booted();
      await _service(runner).restore('emulator-5554');
      expect(
        _commands(runner).any((c) => c.contains('enable')),
        isFalse,
      );
    });

    test('does not wait for a boot it does not need', () async {
      // Restore is the recovery path. Making it depend on the same boot check
      // as apply would mean a wedged emulator could not be put back.
      final runner = _booted();
      await _service(runner).restore('emulator-5554');
      expect(
        _commands(runner).any((c) => c.contains('sys.boot_completed')),
        isFalse,
      );
    });
  });

  group('status', () {
    test('separates our disabled packages from everyone else\'s', () async {
      final runner = FakeCommandRunner(
        responder: (request) {
          final argv = request.arguments.join(' ');
          if (argv.contains('pm list packages')) {
            return _ok(
              'package:com.google.android.gms\npackage:com.android.nfc\n',
            );
          }
          if (argv.contains('window_animation_scale')) return _ok('0\n');
          return _ok('null\n');
        },
      );
      final status = await _service(runner).status('emulator-5554');

      expect(status.disabledManaged, {'com.google.android.gms'});
      expect(status.disabledUnmanaged, {'com.android.nfc'});
      expect(status.settingsSlimmed, isTrue);
      expect(status.isSlimmed, isTrue);
      // `settings get` prints the literal `null` for an unset key, which is the
      // stock state and not a value.
      expect(status.settings['animator_duration_scale'], isNull);
      expect(status.settings['window_animation_scale'], '0');
    });

    test('a stock emulator reports itself as stock', () async {
      final runner = FakeCommandRunner(responder: (_) => _ok('null\n'));
      final status = await _service(runner).status('emulator-5554');
      expect(status.isSlimmed, isFalse);
      expect(status.disabledPackages, isEmpty);
    });

    test('summarises what is here and what will be left alone', () async {
      // The line the Restore row shows. Counts rather than names: the decision
      // it informs is only "press Restore or not", and the unmanaged tail is
      // said out loud because restore deliberately does not touch it.
      final runner = FakeCommandRunner(
        responder: (request) {
          final argv = request.arguments.join(' ');
          if (argv.contains('pm list packages')) {
            return _ok(
              'package:com.google.android.gms\npackage:com.android.nfc\n',
            );
          }
          if (argv.contains('window_animation_scale')) return _ok('0\n');
          return _ok('null\n');
        },
      );
      final status = await _service(runner).status('emulator-5554');

      expect(status.slimmedSettings, {'window_animation_scale'});
      expect(
        status.summary,
        'This app has 1 setting and 1 disabled package on it. '
        '1 package something else disabled is left alone.',
      );
    });

    test('a stock emulator says so instead of naming a count', () {
      const status = AndroidSlimmingStatus(
        serial: 'emulator-5554',
        disabledPackages: {},
        settings: {},
      );
      expect(status.summary, 'Nothing this app applied is on it.');
    });
  });
}
