import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala/src/features/sessions/application/session_prompt_answers.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';
import 'package:agent_cli/process.dart';

/// The write paths into a session's decision record, exercised as the acts that
/// produce them rather than as a DAO call.
///
/// The one property under test throughout: **a row exists only because somebody
/// did something.** Nothing here feeds a conversation to anything.
/// (`decision_record` is the server's now:
/// `server/test/mcp/tools/decision_tool_set_test.dart`.)
void main() {
  late Directory tmp;
  late TestMachine db;
  late ProviderContainer container;
  late LauncherControlServer server;
  late FakeDataServer fake;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('karmashala_decision_tools_');
    db = TestMachine();
    fake = FakeDataServer()..runsOn(db);
    fake.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    fake.projectRows.insert(project());
    fake.repositoryRows.insert(repository());
    fake.installationRows.insert(agentInstallation());
    fake.sessionRows.insert(session(id: 's1', title: 'Work'));
    fake.sessionRows.insert(session(id: 's2', title: 'The verifier'));

    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: db),
        await fake.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    server = LauncherControlServer(container);
    await server.start(
      bridgeFilePath: p.join(tmp.path, 'mcp_bridge.json'),
      socketDirectory: p.join(tmp.path, 'ipc'),
    );
  });

  tearDown(() async {
    await server.stop();
    container.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  List<DecisionRecord> recordOf(String sessionId) =>
      fake.decisionRows.forSession(sessionId);

  Map<String, Object?> handshake() =>
      jsonDecode(File(p.join(tmp.path, 'mcp_bridge.json')).readAsStringSync())
          as Map<String, Object?>;

  Future<({bool isError, String text, Object? structured})> callTool(
    String name, [
    Map<String, Object?> arguments = const {},
    String? asSession,
  ]) async {
    final json = handshake();
    final credential = asSession == null
        ? json['mcpToken']! as String
        : server.callers.tokenFor(asSession);
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${json['port']}/mcp/$credential'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': <String, Object?>{'name': name, 'arguments': arguments},
        }),
      );
      final response = await request.close();
      final body =
          jsonDecode(await response.transform(utf8.decoder).join())
              as Map<String, Object?>;
      final result = body['result'] as Map<String, Object?>?;
      if (result == null) {
        return (
          isError: true,
          text: jsonEncode(body['error']),
          structured: null,
        );
      }
      final content =
          (result['content']! as List<Object?>).first as Map<String, Object?>;
      return (
        isError: result['isError'] == true,
        text: content['text']! as String,
        structured: result['structuredContent'],
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Attaches a live fake pane to [sessionId], so `answerPrompt` has somewhere
  /// to press a key.
  void attachPane(String sessionId) {
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    controller.openTab(TerminalProfile.powerShell);
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .last
        .layout
        .panes
        .first;
    fake.sessionRows.updatePaneId(sessionId, paneId);
  }

  group('an answered approval prompt', () {
    /// An answer in one of this app's panes, as `session_answer` asks for it:
    /// on what the screen shows, whatever the status says.
    Future<SessionApprovalAnswer> answer({required bool approve}) => container
        .read(localPromptAnswersProvider)
        .answer(
          ApprovalAnswerRequest(
            sessionId: 's1',
            approve: approve,
            requireOpenPrompt: false,
          ),
        );

    test('records what the agent said the key does, attributed to the '
        'user', () async {
      attachPane('s1');

      // Not a menu on this screen: the agent's own approve key.
      await answer(approve: true);

      final decision = recordOf('s1').single;
      expect(decision.kind, DecisionKind.approvalGranted);
      // Claude Code's own words for what Enter does, off its own prompt —
      // never our description of what we think was authorised.
      expect(decision.summary, isNotEmpty);
      expect(decision.detail, contains('Answered "Approve"'));
      expect(decision.decidedBy, 'the user');
      expect(decision.origin, DecisionOrigin.approvalPrompt);
      // The prompt is gone the moment it is answered; there is nothing to name.
      expect(decision.originId, isNull);
    });

    test('a refusal is recorded as a refusal, not as an approval', () async {
      attachPane('s1');
      await answer(approve: false);

      // Filing a denial under "approval granted" would make the record say the
      // opposite of what happened.
      expect(recordOf('s1').single.kind, DecisionKind.approachRejected);
    });

    test(
      'session_answer names the agent that answered, not the user',
      () async {
        attachPane('s1');
        final result = await callTool('session_answer', {
          'sessionId': 's1',
          'decision': 'approve',
        }, 's2');

        expect(result.isError, isFalse);
        final decision = recordOf('s1').single;
        expect(decision.decidedBy, contains('s2'));
        expect(decision.recordedBySessionId, 's2');
      },
    );

    test('an answer that never landed records nothing', () async {
      // No pane: the keystroke went nowhere, so nothing was authorised.
      await expectLater(
        answer(approve: true),
        throwsA(
          isA<SessionPromptRefusal>().having(
            (r) => r.noTerminal,
            'noTerminal',
            isTrue,
          ),
        ),
      );
      expect(recordOf('s1'), isEmpty);
    });
  });
}
