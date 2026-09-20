import 'dart:io';

import 'package:agent_cli/src/process/command_runner.dart';
import 'package:agent_cli/src/process/local_command_runner.dart';
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// The `dart:io` handle against real processes: what a dead child's stdin does
/// to the isolate, and what a byte that is not UTF-8 does to a line.
void main() {
  const runner = LocalCommandRunner();

  test(
    'a write in flight when the child dies is not an uncaught error',
    () async {
      final handle = await runner.start(_exitAfterAMoment());
      // Far more than a pipe holds, to a child that never reads: the write is
      // still in flight when the child exits. Unheard, the failure would reach
      // the zone and fail this test on its own.
      final big = 'x' * (1024 * 1024);
      for (var i = 0; i < 8; i++) {
        handle.writeLine(big);
      }
      await handle.exitCode;
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(() => handle.writeLine('still there?'), throwsStateError);
    },
  );

  test(
    'a byte that is not UTF-8 is one wrong character, not a lost line',
    () async {
      final dir = Directory.systemTemp.createTempSync('karmashala_bytes');
      addTearDown(() => removeTempDirectory(dir));
      // The native separator: `type` reads a forward slash as a switch.
      final file = File('${dir.path}${Platform.pathSeparator}out.bin')
        ..writeAsBytesSync([0x68, 0xff, 0x69, 0x0a]);

      final handle = await runner.start(_print(file.path));
      final lines = await handle.stdoutLines.toList();

      expect(lines, ['h\u{FFFD}i']);
      expect(await handle.exitCode, 0);
    },
  );
}

String get _shell => Platform.isWindows ? 'cmd.exe' : 'sh';

CommandRequest _exitAfterAMoment() => CommandRequest(
  executable: _shell,
  arguments: Platform.isWindows
      ? ['/c', 'ping -n 2 127.0.0.1 >NUL & exit 0']
      : ['-c', 'sleep 1; exit 0'],
);

CommandRequest _print(String path) => CommandRequest(
  executable: _shell,
  arguments: Platform.isWindows ? ['/c', 'type', path] : ['-c', 'cat "$path"'],
);
