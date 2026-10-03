import 'dart:convert';

import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_launch/karmashala_launch.dart' show AgentPaneLaunch;
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/session.dart';
import 'package:test/test.dart';

/// Slice 5b's requests, answers and intents cross the wire whole.
void main() {
  /// [request] as a server reads it off the wire.
  DataRequest<Object?> across(DataRequest<Object?> request) =>
      DataRequest.fromJson(
        request.kind,
        (jsonDecode(jsonEncode(request.argumentsToJson())) as Map)
            .cast<String, Object?>(),
      );

  final session = Session(
    id: 's1',
    repositoryId: 'r1',
    agentInstallationId: 'a1',
    title: 'Cart',
    useWorktree: false,
    status: SessionStatus.running,
    createdAt: DateTime.utc(2026, 9, 27),
    externalSessionId: 's1',
  );
  const launch = AgentPaneLaunch(
    agentId: 'claudeCode',
    executable: '/bin/claude',
    arguments: ['--session-id', 's1'],
    workingDirectory: '/src',
    sessionId: 's1',
    title: 'Cart',
  );

  test('sessions.start carries the whole spec', () {
    const spec = SessionStartSpec(
      repositoryId: 'r1',
      installationId: 'a1',
      title: 'Fix',
      titleTyped: true,
      newSession: false,
      surface: SessionSurface.external,
      existingWorktree: EnvironmentPath(environmentId: 'e', path: '/w'),
      workingDirectory: EnvironmentPath(environmentId: 'e', path: '/w/sub'),
      additionalRepositoryIds: ['r2'],
      resumeConversationId: 'c1',
      prompt: 'go',
      systemPrompt: 'packet',
      parentSessionId: 'p',
      parentLink: SessionLink.handoff,
      permissionMode: 'mode=plan',
      modelId: 'opus',
      view: SessionView.terminal,
      columns: 100,
      rows: 30,
    );
    final back = across(const SessionStart(spec)) as SessionStart;
    expect(back.spec.toJson(), spec.toJson());
    expect(back.spec.surface, SessionSurface.external);
    expect(back.spec.parentLink, SessionLink.handoff);
    expect(back.spec.existingWorktree?.path, '/w');
  });

  test('every session request round-trips', () {
    final requests = <DataRequest<Object?>>[
      const SessionResume('s1', restart: true, columns: 90, rows: 20),
      const SessionEndRequest('s1'),
      const SessionSourceBrief('s1', timeoutSeconds: 30),
      const SessionHandoffPreview(
        sessionId: 's1',
        targetAgentName: 'Codex',
        instruction: 'go',
        unresolved: ['a'],
        isFork: true,
        sourceBrief: HandoffSourceBrief.written('brief'),
      ),
      const SessionHandoff(
        sessionId: 's1',
        targetInstallationId: 'c1',
        instruction: 'go',
        unresolved: ['a'],
        newWorktree: true,
        permissionMode: 'mode=plan',
        sourceBrief: HandoffSourceBrief.notWritten('asleep'),
      ),
      const SessionFork(
        sessionId: 's1',
        instruction: 'go',
        unresolved: ['a'],
        newWorktree: true,
      ),
      const SessionForkFromCheckpoint(
        sessionId: 's1',
        turn: 3,
        instruction: 'go',
        confirm: true,
        preview: true,
      ),
      const SessionSwitchAgent(
        sessionId: 's1',
        targetInstallationId: 'i2',
        instruction: 'go',
        permissionMode: 'mode=plan',
      ),
      const SessionSwitchAgent(sessionId: 's1', targetInstallationId: 'i2'),
      const ClientActive(focusedPaneId: 'p1'),
      const ClientActive(),
    ];
    for (final request in requests) {
      final back = across(request);
      expect(back.runtimeType, request.runtimeType, reason: request.kind);
      expect(back.argumentsToJson(), request.argumentsToJson());
    }
  });

  test('answers round-trip', () {
    final started = SessionStarted(
      session: session,
      launch: launch,
      external: const ExternalTerminalCommand(
        executable: '/bin/claude',
        arguments: ['--resume', 'c'],
        workingDirectory: '/src',
        wslDistribution: 'Ubuntu',
      ),
      adopted: true,
      workingDirectoryNotice: 'moved',
      credentialNotice: 'withheld',
      depth: 1,
    );
    const request = SessionStart(
      SessionStartSpec(repositoryId: 'r', installationId: 'a', title: 't'),
    );
    final back = request.resultFromJson(
      jsonDecode(jsonEncode(request.resultToJson(started))),
    );
    expect(back.toJson(), started.toJson());
    expect(back.hostSessionId, 'karmashala_s1');

    const brief = SessionSourceBrief('s1');
    expect(
      brief
          .resultFromJson(
            brief.resultToJson(const HandoffSourceBrief.notWritten('no')),
          )
          .notWritten,
      'no',
    );
    const preview = SessionHandoffPreview(
      sessionId: 's',
      targetAgentName: 'x',
      instruction: 'i',
    );
    expect(preview.resultFromJson(preview.resultToJson('packet')), 'packet');
    const fork = SessionForkFromCheckpoint(sessionId: 's');
    expect(fork.resultFromJson(fork.resultToJson({'preview': true})), {
      'preview': true,
    });
  });

  test('a garbled answer is refused, not misread', () {
    const request = SessionResume('s1');
    expect(
      () => request.resultFromJson('nonsense'),
      throwsA(isA<DataRefused>()),
    );
  });

  test('every intent round-trips', () {
    final intents = <ClientIntent>[
      const OpenSessionTab(sessionId: 's1', title: 'Cart', launch: launch),
      const OpenSessionTab(sessionId: 's1', title: 'Cart'),
      const OpenTerminalTab(paneId: 'p', title: 'run'),
      const CloseTerminalTab('p'),
      const SelectCheckout('r1'),
      const InsertSnippet(snippetId: 'k', paneId: 'p'),
      const InsertSnippet(snippetId: 'k'),
      const OpenImportedSession('i1'),
    ];
    for (final intent in intents) {
      final back = DataChange.fromJson(
        (jsonDecode(jsonEncode(intent.toJson())) as Map)
            .cast<String, Object?>(),
      );
      expect(back.runtimeType, intent.runtimeType);
      expect(back!.toJson(), intent.toJson());
    }
  });
}
