@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Spawning on a real kernel, many times and many at once — what the host does
/// every time an automation's checks run — and a pty reader that must never
/// keep a dead host alive (2026-09-25: a host whose main isolate had died
/// stayed up for ever, silent, holding its sockets, because a reader sat in
/// `read()` on a child that had nothing to say).
///
/// Each runs in a process of its own (`fixtures/`): `dart test` keeps a
/// compiler child alive, and while any `dart:io` child lives, `dart:io`'s exit
/// handler reaps every child of the process and discards the code, so no exit
/// code could be asserted in this one.
void main() {
  late Map<String, Object?> battery;

  setUpAll(() async {
    final run = await Process.run(Platform.resolvedExecutable, [
      'test/pty/fixtures/spawn_battery.dart',
    ]).timeout(const Duration(minutes: 3));
    final said = '${run.stdout}'.trim().split('\n').last;
    expect(run.exitCode, 0, reason: '${run.stdout}${run.stderr}');
    battery = jsonDecode(said) as Map<String, Object?>;
  });

  test('many in a row, argv[0] bare and absolute: the real exit code every '
      'time, and nothing left open in the host', () {
    expect(battery['sequential'], 'ok');
  });

  test('twenty-four at once: each reaped with its own code, no zombie left, '
      'and the spawning isolate never held', () {
    expect(battery['concurrent'], 'ok');
  });

  test('a child inherits no other session\'s pty: its descriptors are the '
      'same with six sessions open as with none', () {
    expect(battery['inheritance'], 'ok');
  });

  test('close() while the child still holds the slave: the reader lets go and '
      'the master is closed within a poll', () {
    expect(battery['closeWhileHeld'], 'ok');
  });

  test('spawning while another isolate starts dart:io processes: every '
      'session ends and nothing is left open', () {
    expect(battery['alongsideDartIo'], 'ok');
  });

  test('a process whose main isolate dies exits, though a pty reader is still '
      'waiting on a child that never speaks', () async {
    final process = await Process.start(Platform.resolvedExecutable, [
      'test/pty/fixtures/session_then_die.dart',
    ]);
    final said = StringBuffer();
    process.stdout.transform(utf8.decoder).listen(said.write);
    process.stderr.transform(utf8.decoder).listen(said.write);
    final code = await process.exitCode.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -999;
      },
    );
    final child = RegExp(r'child (\d+)').firstMatch(said.toString());
    if (child != null) {
      Process.killPid(int.parse(child.group(1)!), ProcessSignal.sigkill);
    }
    expect(child, isNotNull, reason: '$said');
    expect(code, isNot(-999), reason: 'it never exited:\n$said');
    // The VM's own code for an unhandled error.
    expect(code, 255, reason: '$said');
  }, timeout: const Timeout(Duration(seconds: 90)));
}
