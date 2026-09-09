import 'dart:io';

import 'package:agent_cli/src/process/command_runner.dart';
import 'package:agent_cli/src/process/local_command_runner.dart';
import 'package:agent_cli/src/process/process_spawner.dart';
import 'package:test/test.dart';

/// `runInShell` reaching the operating system, not merely being stored.
///
/// The flag exists for executables only a shell can resolve — a Windows
/// app-execution alias, or a `.cmd` shim such as an npm-global `claude.cmd`.
/// [LocalCommandRunner.start] passed it and `run` did not, so an executable of
/// that kind could be launched but never *probed*, and the probe's failure was
/// reported as "not installed".
///
/// The subject here is `ver`, a `cmd.exe` built-in. A `.cmd` shim is the case
/// the flag was *added* for but it turns out to be the wrong witness: given its
/// full path, `Process.run` starts one either way, so it cannot tell a runner
/// that honours the flag from one that drops it. A built-in has no file behind
/// it at all, so the two answers differ — which is the whole property under
/// test.
///
/// Since the creation moved to a worker isolate these also witness the
/// *boundary*: the flag is now read at a `Process.run` on another isolate, so a
/// `runInShell` lost in transit would answer `ver` the way a runner that
/// dropped it always did. `process_spawn_isolate_test.dart` owns the claim
/// about which isolate; this owns the claim that the request arrives whole.
void main() {
  const runner = LocalCommandRunner();

  // The default runner uses the app-wide worker, so this suite is what starts
  // it. Left running, it would outlive the isolate the suite ran in.
  tearDownAll(sharedProcessSpawner.shutdown);

  final windowsOnly = !Platform.isWindows
      ? 'A cmd.exe built-in is a Windows shell case'
      : null;

  test('a shell built-in resolves when the request asks for a shell', () async {
    final result = await runner.run(
      const CommandRequest(executable: 'ver', runInShell: true),
    );
    expect(result.exitCode, 0);
    expect(result.stdout, contains('Windows'));
  }, skip: windowsOnly);

  test('and does not when it does not — which is what the flag is for', () {
    // Not an assertion about a particular message. The point is that the two
    // calls differ at all: a `run` that quietly dropped the flag could not
    // pass this test and the one above at the same time.
    expect(
      runner.run(const CommandRequest(executable: 'ver')),
      throwsA(isA<CommandException>()),
    );
  }, skip: windowsOnly);

  test('start honours it too, as it always did', () async {
    final handle = await runner.start(
      const CommandRequest(executable: 'ver', runInShell: true),
    );
    expect(await handle.exitCode, 0);
  }, skip: windowsOnly);
}
