import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/running/domain/port_label.dart';
import 'package:karmashala/src/features/running/domain/running_board.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import 'running_fixture.dart';

void main() {
  RunningBoard board({
    String? environmentId,
    String? sessionId,
    String query = '',
  }) => buildRunningBoard(
    runningFixture,
    localEnvironmentId: 'windows',
    environmentId: environmentId,
    sessionId: sessionId,
    query: query,
  );

  BoardSession session(RunningBoard board, String title) =>
      board.sessions.singleWhere((s) => s.title == title);

  test('a WSL session\'s port 3000 is a link under that session, on its '
      'machine', () {
    final port = board().ports.singleWhere((p) => p.port.port == 3000);
    expect(port.owner, PortOwner.session);
    expect(port.process.agentSessionId, 'sa');
    expect(port.machine, 'wsl:archlinux');
    expect(port.label.name, 'Vite dev server');
    expect(port.address, 'localhost:3000');
    expect(port.url, 'http://localhost:3000');
    expect(port.forwardedFromWsl, isTrue);

    final analytics = session(board(), 'analytics');
    expect(analytics.machine, 'wsl:archlinux');
    expect(analytics.portCount, 1);
    expect(analytics.headline.first.name, 'node');
    expect(analytics.headline.first.listens, isTrue);
  });

  test('sessions\' ports come first; the server\'s are not among them', () {
    final ports = board().ports;
    expect(ports.first.owner, PortOwner.session);
    expect(ports.where((p) => p.port.port == 47821), isEmpty);
    expect(board().server?.ports, hasLength(4));
    final postgres = ports.singleWhere((p) => p.port.port == 5432);
    expect(postgres.owner, PortOwner.machine);
    expect(postgres.url, isNull, reason: 'a database is not a link');
    expect(
      ports.singleWhere((p) => p.port.port == 5037).owner,
      PortOwner.device,
    );
  });

  test('wrappers are hidden as helpers, and duplicates are one group', () {
    final features = session(board(), 'new features');
    expect(features.helpers.map((p) => p.name).toSet(), {
      'cmd.exe',
      'conhost.exe',
    });
    expect(features.helpers, hasLength(7));
    final testers = features.headline.singleWhere(
      (g) => g.name == 'flutter_tester.exe',
    );
    expect(testers.count, 6);
    // What listens is named first.
    expect(features.headline.first.name, 'dartvm.exe');
    expect(features.others.map((g) => g.name), contains('claude.exe'));
    expect(session(board(), 'analytics').helpers.map((p) => p.name).toSet(), {
      'wsl.exe',
      'cmd.exe',
      'conhost.exe',
      'wslhost.exe',
    });
  });

  test('a port on an SSH box is host:port, never a localhost link', () {
    final port = board().ports.singleWhere((p) => p.port.port == 8080);
    expect(port.address, 'box.example:8080');
    expect(port.url, isNull);
    final deploy = session(board(), 'deploy api');
    expect(deploy.processCount, 1, reason: 'the unread pane is not counted');
  });

  test('a note naming a session sits on its card; the rest on the board', () {
    final reading = RunningReading(
      serverPid: runningFixture.serverPid,
      checkedAt: runningFixture.checkedAt,
      processes: runningFixture.processes,
      notes: const [
        RunningNote(
          '"deploy api" runs on an SSH machine with no connection open; its '
          'processes are not read.',
          environmentId: 'ssh:box',
        ),
        RunningNote('Something else.'),
      ],
    );
    final read = buildRunningBoard(reading, localEnvironmentId: 'windows');
    expect(
      read.sessions.singleWhere((s) => s.title == 'deploy api').notes,
      hasLength(1),
    );
    expect(read.notes.single.text, 'Something else.');
  });

  test('one machine, one session, and a search each narrow it', () {
    expect(board(environmentId: 'wsl:archlinux').sessions.map((s) => s.title), [
      'analytics',
    ]);
    final one = board(sessionId: 'sn');
    expect(one.sessions.single.title, 'new features');
    expect(one.server, isNull);
    expect(one.ports.map((p) => p.port.port), [55134, 56564]);

    final vite = board(query: 'vite');
    expect(vite.ports.map((p) => p.port.port), [3000]);
    expect(vite.sessions.map((s) => s.title), ['analytics']);
    expect(board(query: '5432').ports.single.process.name, 'postgres');
    expect(board(query: 'nothing-like-this').isEmpty, isTrue);
  });

  test('a port bound to the VM\'s own address is not forwarded to Windows', () {
    const process = RunningProcess(pid: 1, parent: 0, role: RunningRole.child);
    BoardPort bound(String address) => BoardPort(
      process: process,
      port: RunningPort(port: 1, address: address),
      label: const PortLabel('x', PortKind.http),
      machine: 'wsl:x',
      owner: PortOwner.session,
    );
    expect(bound('172.22.1.5').forwardedFromWsl, isFalse);
    expect(bound('[::]').forwardedFromWsl, isTrue);
    expect(bound('127.0.0.53').forwardedFromWsl, isTrue);
  });
}
