import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/remote/application/remote_access_controller.dart';
import 'package:karmashala/src/features/ssh/presentation/host_sessions_dialog.dart';
import 'package:karmashala_host_protocol/protocol.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../../support/window_matrix.dart';
import '../terminal/fake_instance.dart';

class _Access extends RemoteAccessController {
  _Access(super.ref);

  @override
  Future<void> sync() async {}
}

/// What a box's host holds, asked of the server (`ssh.hostSessions`, slice
/// 5d): listed, an agent's session named for its session, a shell's offered
/// to reattach, one ended through the server, and a server that cannot reach
/// the box said in its words.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  setUp(() {
    db = TestMachine();
    server = FakeDataServer(clock: () => testTime);
  });

  SessionSummary summary(String id, {bool ended = false}) => SessionSummary(
    id: id,
    argv: const ['/bin/bash', '-l'],
    workingDirectory: '/home/dev',
    pid: 7,
    columns: 80,
    rows: 24,
    startedAt: testTime,
    observedAt: testTime,
    totalBytes: 12,
    firstAvailableOffset: 0,
    lifecycle: ended ? SessionExited(0, testTime) : const SessionRunning(),
    writeHolder: null,
  );

  Future<Widget> dialog() async => ProviderScope(
    overrides: [
      ...fakeTerminalOverrides(
        machine: db,
        data: await server.override(),
      ),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      remoteAccessControllerProvider.overrideWith(_Access.new),
    ],
    child: MaterialApp(home: HostSessionsDialog(host: boxHost)),
  );

  testWidgets('the box\'s sessions are listed, and one is ended through the '
      'server', (tester) async {
    server.sshWork.hostSessions['h1'] = [
      summary('karmashala_local_p1'),
      summary('karmashala_local_p2', ended: true),
    ];
    await tester.pumpWidget(await dialog());
    await tester.pumpAndSettle();

    expect(find.textContaining('/bin/bash -l'), findsNWidgets(2));
    await tester.tap(find.text('End').first);
    await tester.pumpAndSettle();
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
    expect(server.sshWork.endedHostSessions.single, (
      'h1',
      'karmashala_local_p1',
    ));
  });

  testWidgets('a box the server cannot reach is said in its words, never a '
      'dump', (tester) async {
    server.sshWork.hostSessionsRefusal =
        'do-box runs musl libc. The host bundles are glibc-linked ELF.';
    await tester.pumpWidget(await dialog());
    await tester.pumpAndSettle();

    expect(find.textContaining('runs musl libc'), findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
  });

  testWidgets('the failure survives the window matrix', (tester) async {
    server.sshWork.hostSessionsRefusal =
        'The Karmashala host on do-box would not answer.';
    final built = await dialog();
    await expectSurvivesWindowMatrix(
      tester,
      build: () => built,
      because: 'a sentence where a list would be',
    );
  });
}
