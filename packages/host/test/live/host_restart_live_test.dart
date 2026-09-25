@Tags(['live'])
library;

import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

import 'local_host_harness.dart';

/// What a real host, really killed, can answer for when it comes back — the
/// only thing that proves the record was on disk before anybody asked.
void main() {
  test('a session killed with its host comes back readable, and lost', () async {
    final home = temporaryHome('karmashala-host-restart');

    final first = await LocalHost.start(home);
    final before = await LocalHostClient.connect(first.socketPath, 'pane-1');
    before.send(
      OpenMessage(
        requestId: before.nextId(),
        sessionId: 'survivor',
        argv: probeShell,
        environment: const {'TERM': 'xterm-256color'},
        columns: 80,
        rows: 24,
      ),
    );
    final opened = await before.expect<AttachedMessage>();
    before.send(ListMessage(before.nextId()));
    final running = (await before.expect<SessionsMessage>()).summaries.single;
    expect(running.pid, greaterThan(0));
    before
      ..type(opened.sessionRef, setA)
      ..type(opened.sessionRef, setB)
      ..type(opened.sessionRef, echoAB);
    expect(await before.output('karmashala'), isTrue, reason: before.tail(400));
    await before.close();

    // No shutdown, no signal it can act on: this is the app crashing.
    await first.kill();

    // "Did not survive" is only true on Windows because each child is in a job
    // that dies with the host; a terminated host runs no cleanup of its own.
    expect(
      _stillRunning(running.pid),
      isFalse,
      reason: 'a host that was killed must take its children with it',
    );

    final second = await LocalHost.start(home);
    addTearDown(second.kill);
    expect(
      second.greeting,
      contains('restored 1 session(s)'),
      reason:
          'a host that came back holding nothing and one holding a dead '
          'session are different situations',
    );

    final after = await LocalHostClient.connect(second.socketPath, 'pane-1');
    addTearDown(after.close);
    await after.expect<WelcomeMessage>();

    after.send(ListMessage(after.nextId()));
    final listed = await after.expect<SessionsMessage>();
    final summary = listed.summaries.singleWhere((s) => s.id == 'survivor');
    expect(summary.lifecycle.hasEnded, isTrue);
    // Never a zero: the process did not exit, it died with the host.
    expect(summary.lifecycle.exitCode, isNull);
    expect(
      summary.lifecycle.describe(),
      contains('host stopped while running'),
    );
    expect(summary.totalBytes, greaterThan(0));

    // And the scrollback is answerable for, from the start and from a point.
    after.send(
      AttachMessage(
        requestId: after.nextId(),
        sessionId: 'survivor',
        sinceOffset: 0,
        claimWrite: false,
      ),
    );
    final attached = await after.expect<AttachedMessage>();
    expect(attached.replayFromOffset, 0);
    expect(attached.droppedBytes, 0);
    expect(await after.output('karmashala'), isTrue, reason: after.tail(400));

    // The pane learns the session is over, with the reason rather than a code.
    final exited = await after.expect<ExitedMessage>();
    expect(exited.exitCode, isNull);
    expect(exited.reason, contains('host stopped while running'));

    // A dead session does not hold its id: reopening it starts a process.
    after.send(
      OpenMessage(
        requestId: after.nextId(),
        sessionId: 'survivor',
        argv: probeShell,
        environment: const {},
        columns: 80,
        rows: 24,
      ),
    );
    final reopened = await after.expect<AttachedMessage>();
    expect(reopened.totalBytes, 0, reason: 'a new session starts from nothing');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// Whether [pid] is still alive: a handle that will not open is a process that
/// is gone. Pids are reused, so this is only asked seconds after it was seen.
bool _stillRunning(int pid) {
  if (!Platform.isWindows) {
    return Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
  }
  final k = Kernel32.open();
  final handle = k.openProcess(
    kProcessQueryLimitedInformation | kSynchronize,
    0,
    pid,
  );
  if (handle == 0) return false;
  try {
    return k.waitForSingleObject(handle, 0) != kWaitObject0;
  } finally {
    k.closeHandle(handle);
  }
}
