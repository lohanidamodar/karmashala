import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/terminals_client.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_host/karmashala_host.dart';

import '../support/fake_data_server.dart';
import '../support/fixtures.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart' show SessionResume;

/// Which pane the *real* factory builds (slice 5a): every local and WSL pane
/// is a terminal the server runs — asked for with `terminals.open`, attached
/// to by the session its id names — and nothing runs in the app.
void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('ksw');
  });
  tearDown(() {
    try {
      home.deleteSync(recursive: true);
    } on FileSystemException {
      // A socket node can still be held on Windows.
    }
  });

  /// An access in a folder of its own with no binary to start, so a pane that
  /// measures it can neither reach nor start the host of the person running
  /// the tests.
  LocalHostSessionAccess inertAccess() => LocalHostSessionAccess(
    paths: HostPaths(Directory('${home.path}/.k'))..ensureDirectory(),
    executable: LocalHostExecutable(
      executableDirectory: '${home.path}/absent',
      repositoryRoot: '${home.path}/absent',
    ),
  );

  Future<ProviderContainer> containerWith(
    FakeDataServer server, {
    LocalHostSessionAccess? access,
  }) async {
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        localHostSessionAccessProvider.overrideWithValue(access),
      ],
    );
    addTearDown(container.dispose);
    // The server's profiles, asked once the client is up.
    container.read(terminalServerProfilesProvider);
    await pumpEventQueue();
    return container;
  }

  TerminalInstance open(
    ProviderContainer container, {
    TerminalProfile profile = const TerminalProfile(
      id: 'posix:/bin/zsh',
      label: 'zsh',
      shell: TerminalShell.posix,
      posixShellPath: '/bin/zsh',
    ),
    AgentPaneLaunch? agentLaunch,
    String? workingDirectory,
  }) {
    final pane = container.read(terminalInstanceFactoryProvider)(
      id: 'p1',
      profile: profile,
      agentLaunch: agentLaunch,
      workingDirectory: workingDirectory,
      shellIntegration: true,
    );
    addTearDown(pane.dispose);
    return pane;
  }

  test('a local pane is the server\'s terminal, under its pane id', () async {
    final server = FakeDataServer();
    final container = await containerWith(server, access: inertAccess());
    final pane = open(container, workingDirectory: '/src/app');
    expect(pane, isA<HostTerminalInstance>());
    final host = pane as HostTerminalInstance;
    expect(host.sessionId, 'karmashala_local_p1');
    expect(host.attachOnly, isFalse);

    final opening = await host.opener!(100, 30);
    expect(opening.sessionId, 'karmashala_local_p1');
    final asked = server.terminals.opened.single;
    expect(asked.paneId, 'p1');
    expect(asked.profileId, 'posix:/bin/zsh');
    expect(asked.workingDirectory, '/src/app');
    expect((asked.columns, asked.rows), (100, 30));
    expect(asked.shellIntegration, isTrue);
    expect(asked.agentLaunch, isNull);
  });

  test('a profile the server does not offer asks for its default', () async {
    final server = FakeDataServer();
    final container = await containerWith(server, access: inertAccess());
    final pane =
        open(container, profile: TerminalProfile.powerShell)
            as HostTerminalInstance;
    await pane.opener!(80, 24);
    expect(server.terminals.opened.single.profileId, isNull);
  });

  test('an agent pane is its session\'s: the server resumes it, and the '
      'pane attaches under its row (slice 5b)', () async {
    final server = FakeDataServer();
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    server.sessionRows.insert(session(id: 's1', title: 'Fix it'));
    final container = await containerWith(server, access: inertAccess());
    final pane =
        open(
              container,
              agentLaunch: const AgentPaneLaunch(
                agentId: 'claudeCode',
                executable: 'claude',
                mcpArguments: ['--mcp-config', '/tmp/m.json'],
                workingDirectory: '/src/app',
                sessionId: 's1',
                title: 'Fix it',
              ),
            )
            as HostTerminalInstance;
    expect(pane.sessionId, 'karmashala_s1');
    final opened = await pane.opener!(80, 24);
    expect(opened.sessionId, 'karmashala_s1');
    // The server was asked to resume the row — never handed this client's
    // command line, MCP flags and all.
    final asked = server.sessionWork.asked.whereType<SessionResume>().single;
    expect(asked.sessionId, 's1');
    expect((asked.columns, asked.rows), (80, 24));
    expect(server.terminals.opened, isEmpty);
  });

  test('a refusal is thrown in the server\'s words', () async {
    final server = FakeDataServer()
      ..terminals.refuseWith = 'no such shell here';
    final container = await containerWith(server, access: inertAccess());
    final pane = open(container) as HostTerminalInstance;
    await expectLater(
      pane.opener!(80, 24),
      throwsA(
        isA<TerminalRefused>().having(
          (e) => '$e',
          'words',
          'no such shell here',
        ),
      ),
    );
  });

  test('with no server to reach, the pane says so; nothing runs here', () async {
    final server = FakeDataServer();
    final container = await containerWith(server);
    final pane = open(container);
    expect(pane, isA<ErrorTerminalInstance>());
    expect(server.terminals.opened, isEmpty);
  });

  test('a restored pane and a hosted run only attach', () async {
    final server = FakeDataServer();
    final container = await containerWith(server, access: inertAccess());
    final restored = container.read(restoredPaneFactoryProvider)(
      id: 'p2',
      profile: TerminalProfile.posix('/bin/zsh'),
    );
    addTearDown(() => restored?.dispose());
    expect((restored! as HostTerminalInstance).attachOnly, isTrue);
    final run = container.read(hostedRunPaneFactoryProvider)(
      id: 'hosted-r1',
      title: 'run',
    );
    addTearDown(() => run?.dispose());
    expect((run! as HostTerminalInstance).sessionId, 'karmashala_local_hosted-r1');
    expect((run as HostTerminalInstance).attachOnly, isTrue);
  });
}
