@Tags(['live'])
library;


import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

import 'local_host_harness.dart';

/// What a real host, really killed, can answer for when it comes back.
///
/// The unit tests build the registry twice over one store; this kills the
/// process — which is the only thing that proves the record was on disk before
/// anybody asked for it, rather than written on the way out.
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

    // No shutdown, no signal it can act on: the process goes, and the child
    // with it. This is the app crashing, and the case the whole stage is for.
    await first.kill();

    // The sentence the restore path prints says the process "did not survive".
    // On Windows a terminated host runs no cleanup of its own, so this is only
    // true because each child is in a job that dies with it.
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
      reason: 'a host that came back holding nothing and one holding a dead '
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
    expect(summary.lifecycle.describe(), contains('did not survive'));
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
    expect(exited.reason, contains('did not survive'));

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

/// Whether [pid] names a process that is still alive right now.
///
/// A handle that cannot be opened is a process that is gone; one that opens and
/// is already signalled has exited. Pids are reused, so this is only asked
/// seconds after the process in question was seen.
bool _stillRunning(int pid) {
  final k = Kernel32.open();
  final handle = k.openProcess(kProcessQueryLimitedInformation | kSynchronize, 0, pid);
  if (handle == 0) return false;
  try {
    return k.waitForSingleObject(handle, 0) != kWaitObject0;
  } finally {
    k.closeHandle(handle);
  }
}
