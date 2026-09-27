import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_launch/karmashala_launch.dart';
import 'package:test/test.dart';

/// Terminals the server runs (slice 5a) — profiles, a start, the list, a
/// close and a rename — and the changes its screens tell, through the
/// envelope as JSON text.
void main() {
  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  R roundTrip<R>(DataRequest<R> request, R result) => DataEnvelope.readAnswer(
    overTheWire(DataEnvelope.answer(4, request, DataReply(result, 9, const []))),
    request,
  ).value;

  const agent = AgentPaneLaunch(
    agentId: 'claudeCode',
    executable: '/usr/local/bin/claude',
    arguments: ['--session-id', 's1'],
    mcpArguments: ['--mcp-config', '/tmp/mcp.json'],
    environment: {'DISABLE_AUTOUPDATER': '1'},
    removedEnvironment: {'ANTHROPIC_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN'},
    workingDirectory: '/home/me/app',
    wslDistribution: 'Ubuntu',
    sessionId: 's1',
    title: 'Fix the build',
  );

  final requests = <TerminalWorkRequest<Object?>>[
    const TerminalsProfiles(),
    const TerminalOpen(paneId: 'p1', columns: 80, rows: 24),
    const TerminalOpen(
      paneId: 'p2',
      environmentId: 'wsl:Ubuntu',
      workingDirectory: '/home/me',
      profileId: 'wsl:Ubuntu',
      columns: 120,
      rows: 40,
      shellIntegration: true,
    ),
    const TerminalOpen(
      paneId: 'p3',
      agentLaunch: agent,
      columns: 100,
      rows: 30,
    ),
    const TerminalsList(),
    const TerminalClose('karmashala_local_p1'),
    const TerminalRename('karmashala_local_p1', 'build'),
  ];

  test('every request round-trips with its arguments', () {
    for (final request in requests) {
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(3, request)),
      );
      expect(read.refusal, isNull, reason: request.kind);
      expect(read.request, isA<TerminalWorkRequest<Object?>>());
      expect(read.request!.runtimeType, request.runtimeType);
      expect(
        read.request!.argumentsToJson(),
        request.argumentsToJson(),
        reason: request.kind,
      );
    }
  });

  test('an agent launch crosses whole, its volatile parts included', () {
    final read =
        DataEnvelope.readRequest(
              overTheWire(DataEnvelope.request(1, requests[3])),
            ).request!
            as TerminalOpen;
    final launch = read.agentLaunch!;
    expect(launch.executable, agent.executable);
    expect(launch.arguments, agent.arguments);
    expect(launch.mcpArguments, agent.mcpArguments);
    expect(launch.environment, agent.environment);
    expect(launch.removedEnvironment, agent.removedEnvironment);
    expect(launch.wslDistribution, 'Ubuntu');
    expect(launch.sessionId, 's1');
    expect(launch.title, 'Fix the build');
  });

  test('answers are typed', () {
    final profiles = roundTrip(const TerminalsProfiles(), [
      TerminalProfile.posix('/bin/zsh', isLoginShell: true),
      TerminalProfile.powerShell,
      const TerminalProfile(
        id: 'wsl:Ubuntu',
        label: 'Ubuntu (WSL)',
        shell: TerminalShell.wsl,
        wslDistribution: 'Ubuntu',
      ),
    ]);
    expect(profiles.map((p) => p.id), ['posix:/bin/zsh', 'powershell', 'wsl:Ubuntu']);
    expect(profiles.first.posixShellPath, '/bin/zsh');
    expect(profiles.last.wslDistribution, 'Ubuntu');

    final opened = roundTrip(
      requests[1] as TerminalOpen,
      const TerminalOpened(
        sessionId: 'karmashala_local_p1',
        paneId: 'p1',
        title: 'zsh',
        profileId: 'posix:/bin/zsh',
        shellIntegration: true,
        adopted: true,
      ),
    );
    expect(opened.sessionId, 'karmashala_local_p1');
    expect(opened.shellIntegration, isTrue);
    expect(opened.adopted, isTrue);

    final started = DateTime.utc(2026, 9, 27, 10);
    final list = roundTrip(const TerminalsList(), [
      TerminalRecord(
        sessionId: 'karmashala_local_p1',
        paneId: 'p1',
        profileId: 'posix:/bin/zsh',
        environmentId: 'local',
        title: 'vim',
        workingDirectory: '/src',
        lastCommand: 'make',
        lastCommandExitCode: 2,
        startedAt: started,
      ),
      TerminalRecord(
        sessionId: 'karmashala_s1',
        paneId: 'p3',
        profileId: 'agent:claudeCode',
        title: 'claude',
        startedAt: started,
        endedAt: started.add(const Duration(minutes: 1)),
        endReason: 'the server stopped',
      ),
    ]);
    expect(list.first.isLive, isTrue);
    expect(list.first.lastCommandExitCode, 2);
    expect(list.last.isLive, isFalse);
    expect(list.last.exitCode, isNull);
    expect(list.last.endReason, 'the server stopped');
  });

  test('changes round-trip', () {
    final record = TerminalRecord(
      sessionId: 'karmashala_local_p1',
      paneId: 'p1',
      profileId: 'powershell',
      title: 'PowerShell',
      startedAt: DateTime.utc(2026, 9, 27),
      exitCode: 0,
      endedAt: DateTime.utc(2026, 9, 27, 1),
    );
    final changed =
        DataChange.fromJson(overTheWire(TerminalChanged(record).toJson()))!
            as TerminalChanged;
    expect(changed.terminal.exitCode, 0);
    expect(changed.terminal.title, 'PowerShell');
    final removed =
        DataChange.fromJson(
              overTheWire(const TerminalRemoved('karmashala_local_p1').toJson()),
            )!
            as TerminalRemoved;
    expect(removed.sessionId, 'karmashala_local_p1');
  });

  test('the session id rule is the hosted runs\' for a pane, the row\'s for '
      'an agent', () {
    expect(terminalSessionId(paneId: 'p/1'), 'karmashala_local_p_1');
    expect(terminalSessionId(paneId: 'p/1'), hostedRunSessionId('p/1'));
    expect(
      terminalSessionId(paneId: 'p1', agentSessionId: 's.1'),
      'karmashala_s_1',
    );
  });
}
