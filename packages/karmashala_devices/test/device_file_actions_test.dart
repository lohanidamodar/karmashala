import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:agent_cli/process.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala_devices/devices.dart';

import 'support/fake_command_runner.dart';
import 'fake_scrcpy_control_channel.dart';

/// The file browser's moving parts, without a phone and without a dialog.
///
/// What is asserted is the **sentence the user ends up reading** — a partial
/// paste that reported only its last result is how somebody comes to believe
/// six files moved when two did — and the host paths, which is where a device
/// id turning into a filename goes wrong on Windows.
const _serial = 'emulator-5554';
// A temp root this host could hand the staging code, which joins with the
// host's own separator.
final _temp = Platform.isWindows ? r'C:\Temp' : '/tmp';

AndroidSdk _sdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\platform-tools\adb.exe',
  ),
);

AdbDeviceDriver _driver(AdbService adb, {String serial = _serial}) =>
    AdbDeviceDriver(
      adb: adb,
      target: AndroidTarget(
        AndroidDevice(
          serial: serial,
          environmentId: 'windows',
          state: DeviceConnectionState.device,
        ),
      ),
    );

CommandResult _out(String stdout) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');

CommandResult _lsOut(String listing) =>
    _out(base64.encode(utf8.encode(listing)));

String _fileRow(String name) =>
    '-rw-rw---- 1 u0_a1 media_rw 12 2026-09-07 10:00 $name';
String _dirRow(String name) =>
    'drwxrwx--- 2 u0_a1 media_rw 4096 2026-09-07 10:00 $name';

/// A device whose `ls -lad` answers per path; `cp`, `mv`, `pull` and `push`
/// succeed unless [failPathContaining] appears in the command.
FakeCommandRunner _runner(
  Map<String, String> stats, {
  String? failPathContaining,
}) => FakeCommandRunner(
  responder: (request) {
    final argv = request.arguments;
    final command = argv.last;
    if (failPathContaining != null && command.contains(failPathContaining)) {
      if (argv.contains('pull') || argv.contains('push')) {
        return CommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'adb: error: failed to stat remote object',
        );
      }
      if (!command.startsWith('ls ')) {
        return CommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'Permission denied',
        );
      }
    }
    if (argv.contains('pull') || argv.contains('push')) {
      // `adb pull`/`push` print their summary on **stderr with exit 0**.
      return CommandResult(
        exitCode: 0,
        stdout: '',
        stderr: '1 file pulled, 0 skipped. 12 bytes in 0.001s',
      );
    }
    for (final entry in stats.entries) {
      if (command.contains("ls -lad '${entry.key}'")) {
        return _lsOut(entry.value);
      }
    }
    if (command.startsWith('ls -lad ')) {
      return _lsOut('ls: x: No such file or directory');
    }
    return _out('');
  },
);

DeviceFileEntry _file(String path) => DeviceFileEntry(
  path: path,
  name: path.split('/').last,
  kind: DeviceEntryKind.file,
);

DeviceFileEntry _dir(String path) => DeviceFileEntry(
  path: path,
  name: path.split('/').last,
  kind: DeviceEntryKind.directory,
);

void main() {
  group('pasteOnDevice', () {
    test('copies each entry and names what it did', () async {
      final runner = _runner({
        '/sdcard/a.txt': _fileRow('a.txt'),
        '/sdcard/b.txt': _fileRow('b.txt'),
        '/sdcard/Download': _dirRow('Download'),
      });
      final report = await pasteOnDevice(
        driver: _driver(AdbService(runner: runner, sdk: _sdk())),
        clip: DeviceFileClipboard(
          serial: _serial,
          entries: [_file('/sdcard/a.txt'), _file('/sdcard/b.txt')],
          mode: DeviceFileClipboardMode.copy,
        ),
        directory: '/sdcard/Download',
      );
      expect(report.message, contains('Copied a.txt, b.txt'));
      expect(report.message, contains('/sdcard/Download'));
      expect(report.deviceChanged, isTrue);
    });

    test('a cut reports a move, not a copy', () async {
      final runner = _runner({'/sdcard/a.txt': _fileRow('a.txt')});
      final report = await pasteOnDevice(
        driver: _driver(AdbService(runner: runner, sdk: _sdk())),
        clip: DeviceFileClipboard(
          serial: _serial,
          entries: [_file('/sdcard/a.txt')],
          mode: DeviceFileClipboardMode.cut,
        ),
        directory: '/sdcard/Download',
      );
      expect(report.message, startsWith('Moved a.txt'));
    });

    test(
      'the clipboard refusal is reported and nothing is attempted',
      () async {
        final runner = _runner(const {});
        final report = await pasteOnDevice(
          driver: _driver(AdbService(runner: runner, sdk: _sdk())),
          clip: DeviceFileClipboard(
            serial: 'F6IZLV6LMFT4U4ZT',
            entries: [_file('/sdcard/a.txt')],
            mode: DeviceFileClipboardMode.copy,
          ),
          directory: '/sdcard/Download',
        );
        expect(report.message, contains('pull followed by a push'));
        expect(report.deviceChanged, isFalse);
        expect(runner.requests, isEmpty);
      },
    );

    test('a partial paste says what moved before it stopped', () async {
      // The failure this exists for: reporting only the last result makes six
      // files look moved when two were.
      final runner = _runner({
        '/sdcard/a.txt': _fileRow('a.txt'),
        '/sdcard/b.txt': _fileRow('b.txt'),
        '/sdcard/Download': _dirRow('Download'),
      }, failPathContaining: 'b.txt');
      final report = await pasteOnDevice(
        driver: _driver(AdbService(runner: runner, sdk: _sdk())),
        clip: DeviceFileClipboard(
          serial: _serial,
          entries: [_file('/sdcard/a.txt'), _file('/sdcard/b.txt')],
          mode: DeviceFileClipboardMode.copy,
        ),
        directory: '/sdcard/Download',
      );
      expect(report.message, contains('Copied a.txt, then stopped'));
      expect(report.message, contains('Permission denied'));
      // Something did move, so the listing is stale even though it failed.
      expect(report.deviceChanged, isTrue);
    });
  });

  group('copyToHostClipboard', () {
    test(
      'stages under the fileSafeId and puts the paths on the clipboard',
      () async {
        final host = FakeHostClipboard();
        final made = <String>[];
        final report = await copyToHostClipboard(
          driver: _driver(
            AdbService(
              runner: _runner({'/sdcard/a.txt': _fileRow('a.txt')}),
              sdk: _sdk(),
            ),
            serial: '192.168.1.24:37129',
          ),
          host: host,
          temporaryDirectory: _temp,
          entries: [_file('/sdcard/a.txt')],
          makeDirectory: (path) async => made.add(path),
        );
        expect(report.message, contains('paste it anywhere'));
        // The one assertion this whole path exists for: no colon in the host
        // path, because on Windows a colon opens an alternate data stream and
        // the pull then reports success having written nothing readable.
        expect(made.single, endsWith('${p.separator}192.168.1.24-37129'));
        expect(made.single.substring(_temp.length), isNot(contains(':')));
        expect(
          host.filesWritten.single.single,
          endsWith('-37129${p.separator}a.txt'),
        );
        expect(
          host.filesWritten.single.single.substring(_temp.length),
          isNot(contains(':')),
        );
      },
    );

    test('a directory is refused rather than walked', () async {
      final host = FakeHostClipboard();
      final report = await copyToHostClipboard(
        driver: _driver(AdbService(runner: _runner(const {}), sdk: _sdk())),
        host: host,
        temporaryDirectory: _temp,
        entries: [_dir('/sdcard/DCIM')],
        makeDirectory: (_) async {},
      );
      expect(report.message, contains('is a directory'));
      expect(host.filesWritten, isEmpty);
    });

    test(
      'a clipboard that refuses the files still says where they are',
      () async {
        // The copy worked; only the clipboard did not. Reporting a failed copy
        // would be false, and the files would be unfindable.
        final host = FakeHostClipboard()..acceptsFiles = false;
        final report = await copyToHostClipboard(
          driver: _driver(
            AdbService(
              runner: _runner({'/sdcard/a.txt': _fileRow('a.txt')}),
              sdk: _sdk(),
            ),
          ),
          host: host,
          temporaryDirectory: _temp,
          entries: [_file('/sdcard/a.txt')],
          makeDirectory: (_) async {},
        );
        expect(report.message, contains('would not take the files'));
        expect(
          report.message,
          contains(p.join(_temp, 'karmashala-device-files')),
        );
      },
    );

    test('a pull that fails is reported as itself', () async {
      final host = FakeHostClipboard();
      final report = await copyToHostClipboard(
        driver: _driver(
          AdbService(
            runner: _runner({
              '/sdcard/a.txt': _fileRow('a.txt'),
            }, failPathContaining: 'a.txt'),
            sdk: _sdk(),
          ),
        ),
        host: host,
        temporaryDirectory: _temp,
        entries: [_file('/sdcard/a.txt')],
        makeDirectory: (_) async {},
      );
      expect(report.message, contains('Could not copy /sdcard/a.txt'));
      expect(host.filesWritten, isEmpty);
    });
  });

  group('pasteFromHostClipboard', () {
    test(
      'pushes every file on the clipboard into the open directory',
      () async {
        final host = FakeHostClipboard(
          files: [r'C:\Users\x\Desktop\one.png', r'C:\Users\x\Desktop\two.png'],
        );
        final report = await pasteFromHostClipboard(
          driver: _driver(
            AdbService(
              runner: _runner({'/sdcard/Download': _dirRow('Download')}),
              sdk: _sdk(),
            ),
          ),
          host: host,
          directory: '/sdcard/Download',
        );
        expect(report.message, 'Copied one.png, two.png to /sdcard/Download.');
        expect(report.deviceChanged, isTrue);
      },
    );

    test('an empty file clipboard says so, and says why it might be', () async {
      // The usual reason is that what was copied was text, and "paste failed"
      // sends the user looking at the phone instead of at their own clipboard.
      final report = await pasteFromHostClipboard(
        driver: _driver(AdbService(runner: _runner(const {}), sdk: _sdk())),
        host: FakeHostClipboard(),
        directory: '/sdcard/Download',
      );
      expect(report.message, contains('no files on this computer'));
      expect(report.message, contains('does not paste as a file'));
      expect(report.deviceChanged, isFalse);
    });

    test(
      'an existing file is refused and the refusal is the push\'s own',
      () async {
        final host = FakeHostClipboard(files: [r'C:\Users\x\Desktop\a.txt']);
        final report = await pasteFromHostClipboard(
          driver: _driver(
            AdbService(
              runner: _runner({
                '/sdcard/Download': _dirRow('Download'),
                '/sdcard/Download/a.txt': _fileRow('a.txt'),
              }),
              sdk: _sdk(),
            ),
          ),
          host: host,
          directory: '/sdcard/Download',
        );
        expect(report.message, contains('already exists'));
        expect(report.message, contains('no undo'));
        expect(report.deviceChanged, isFalse);
      },
    );
  });

  group('what each operation costs', () {
    // Counted, never timed. Every one of these is a process, so the number is
    // the thing worth pinning — and the number changing is how a check gets
    // added or lost without anybody noticing.
    test('a device-side paste is three adb calls and no transfer', () async {
      final runner = _runner({
        '/sdcard/a.txt': _fileRow('a.txt'),
        '/sdcard/Download': _dirRow('Download'),
      });
      await pasteOnDevice(
        driver: _driver(AdbService(runner: runner, sdk: _sdk())),
        clip: DeviceFileClipboard(
          serial: _serial,
          entries: [_file('/sdcard/a.txt')],
          mode: DeviceFileClipboardMode.copy,
        ),
        directory: '/sdcard/Download',
      );
      // stat the source, stat the destination *file*, then one `cp`. Paste
      // names the destination file rather than the folder, so the
      // "it is a directory, put it inside" branch — and its extra stat — is
      // never taken from here.
      expect(runner.requests, hasLength(3));
      expect(
        runner.requests.where(
          (request) =>
              request.arguments.contains('pull') ||
              request.arguments.contains('push'),
        ),
        isEmpty,
        reason: 'nothing crosses the wire; that is the whole point',
      );
      // And nothing was started with `start`, so nothing is left running.
      expect(runner.startRequests, isEmpty);
    });

    test('copying one file to this computer is two adb calls', () async {
      final runner = _runner({'/sdcard/a.txt': _fileRow('a.txt')});
      await copyToHostClipboard(
        driver: _driver(AdbService(runner: runner, sdk: _sdk())),
        host: FakeHostClipboard(),
        temporaryDirectory: _temp,
        entries: [_file('/sdcard/a.txt')],
        makeDirectory: (_) async {},
      );
      // stat, then pull.
      expect(runner.requests, hasLength(2));
      expect(runner.requests.last.arguments, contains('pull'));
    });

    test('pasting one file from this computer is three adb calls', () async {
      final runner = _runner({'/sdcard/Download': _dirRow('Download')});
      await pasteFromHostClipboard(
        driver: _driver(AdbService(runner: runner, sdk: _sdk())),
        host: FakeHostClipboard(files: [r'C:\Users\x\a.txt']),
        directory: '/sdcard/Download',
      );
      // stat the destination, stat the name inside it, then one `push`.
      expect(runner.requests, hasLength(3));
      expect(runner.requests.last.arguments, contains('push'));
    });

    test('an empty host clipboard costs no adb call at all', () async {
      final runner = _runner(const {});
      await pasteFromHostClipboard(
        driver: _driver(AdbService(runner: runner, sdk: _sdk())),
        host: FakeHostClipboard(),
        directory: '/sdcard/Download',
      );
      expect(runner.requests, isEmpty);
    });
  });
}
