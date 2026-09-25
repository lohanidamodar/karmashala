import 'dart:convert';
import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/mcp/decision_tools.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/data/decision_record_dao.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala/src/features/verification/domain/verification_run.dart';
import 'package:karmashala/src/features/verification/domain/verification_target.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// The write paths into a session's decision record, exercised as the acts that
/// produce them rather than as a DAO call.
///
/// The one property under test throughout: **a row exists only because somebody
/// did something.** Nothing here feeds a conversation to anything.
void main() {
  late Directory tmp;
  late AppDatabase db;
  late ProviderContainer container;
  late LauncherControlServer server;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('karmashala_decision_tools_');
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db).insert(session(id: 's1', title: 'Work'));
    SessionDao(db).insert(session(id: 's2', title: 'The verifier'));

    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
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
    db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  List<DecisionRecord> recordOf(String sessionId) =>
      DecisionRecordDao(db).forSession(sessionId);

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
    SessionDao(db).updatePaneId(sessionId, paneId);
  }

  group('decision_record', () {
    test('writes what the agent decided, in the agent\'s own words', () async {
      final result = await callTool('decision_record', {
        'kind': 'rejected',
        'summary': 'The isolate pool deadlocked on Windows.',
        'detail': 'Two workers, both waiting on the same send port.',
      }, 's1');

      expect(result.isError, isFalse);
      final decision = recordOf('s1').single;
      expect(decision.kind, DecisionKind.approachRejected);
      // Stored exactly as given. A gist would be a claim nobody made.
      expect(decision.summary, 'The isolate pool deadlocked on Windows.');
      expect(
        decision.detail,
        'Two workers, both waiting on the same send port.',
      );
      expect(decision.origin, DecisionOrigin.decisionTool);
      expect(decision.recordedBySessionId, 's1');
      // Attributed by name, because the packet's reader cannot resolve an id.
      expect(decision.decidedBy, 'Claude Code');
      expect(decision.sequence, 1);
    });

    test('defaults to the calling session, and can name another', () async {
      await callTool('decision_record', {
        'kind': 'constraint',
        'summary': 'Windows is the primary target.',
      }, 's1');
      await callTool('decision_record', {
        'kind': 'constraint',
        'summary': "Recorded onto someone else's work.",
        'sessionId': 's1',
      }, 's2');

      expect(recordOf('s1'), hasLength(2));
      expect(recordOf('s2'), isEmpty);
      // Naming a target does not rewrite who asked.
      expect(recordOf('s1').last.recordedBySessionId, 's2');
    });

    test('an agent cannot forge an approval the user never gave', () async {
      for (final kind in const ['approval', 'verification', 'checkpoint']) {
        final result = await callTool('decision_record', {
          'kind': kind,
          'summary': 'The user said yes to everything.',
        }, 's1');
        expect(result.isError, isTrue, reason: kind);
        expect(result.text, contains('kind must be one of'));
      }
      expect(recordOf('s1'), isEmpty);
    });

    test('a blank decision is refused rather than counted', () async {
      final result = await callTool('decision_record', {
        'kind': 'constraint',
        'summary': '   ',
      }, 's1');
      expect(result.isError, isTrue);
      expect(result.text, contains('summary is required'));
      expect(recordOf('s1'), isEmpty);
    });

    test('a caller with no session of its own must name one', () async {
      final result = await callTool('decision_record', {
        'kind': 'constraint',
        'summary': 'Anonymous.',
      });
      expect(result.isError, isTrue);
      expect(result.text, contains('not running inside a session'));
    });

    test('recording the same decision twice appends, never rewrites', () async {
      await callTool('decision_record', {
        'kind': 'constraint',
        'summary': 'No isolates.',
      }, 's1');
      await callTool('decision_record', {
        'kind': 'constraint',
        'summary': 'No isolates.',
      }, 's1');

      final rows = recordOf('s1');
      expect(rows, hasLength(2));
      expect(rows.first.sequence, 1);
      expect(rows.last.sequence, 2);
    });
  });

  group('an answered approval prompt', () {
    test('records what the agent said the key does, attributed to the '
        'user', () {
      attachPane('s1');

      // The card's path: press the agent's own approve key.
      expect(
        container.read(sessionLauncherProvider).answerPrompt('s1', '\r'),
        isTrue,
      );

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

    test('a refusal is recorded as a refusal, not as an approval', () {
      attachPane('s1');
      container.read(sessionLauncherProvider).answerPrompt('s1', '\x1b');

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

    test('a keystroke the agent never named records nothing', () {
      attachPane('s1');
      // True because the key reached the terminal — this method also carries
      // answers we did not compose — and empty because guessing at what an
      // unrecognised keystroke authorised is exactly the inference the record
      // must not contain.
      expect(
        container.read(sessionLauncherProvider).answerPrompt('s1', 'y'),
        isTrue,
      );
      expect(recordOf('s1'), isEmpty);
    });

    test('an answer that never landed records nothing', () {
      // No pane: the keystroke went nowhere, so nothing was authorised.
      expect(
        container.read(sessionLauncherProvider).answerPrompt('s1', '\r'),
        isFalse,
      );
      expect(recordOf('s1'), isEmpty);
    });
  });

  group('a finished verification run', () {
    VerificationRun run({
      String? sessionId = 's1',
      VerificationVerdict? verdict = VerificationVerdict.pass,
      String? producedBy = 's2',
      String? reason = 'The header row renders.',
    }) => VerificationRun(
      id: 'v-1',
      title: 'Login page',
      target: VerificationTarget.browser('http://localhost:8080'),
      startedAt: testTime,
      artifactDirectory: r'C:\art\v-1',
      sessionId: sessionId,
      producedBySessionId: producedBy,
      verdict: verdict,
      reason: reason,
    );

    test('lands on the record of the session whose work it was about', () {
      recordFinishedVerdict(container, run());

      // The subject's record, not the verifier's: whoever takes *that* work
      // over is the one who would otherwise re-run a check that passed.
      expect(recordOf('s2'), isEmpty);
      final decision = recordOf('s1').single;
      expect(decision.kind, DecisionKind.verificationVerdict);
      expect(decision.summary, contains('Pass'));
      expect(decision.summary, contains('Login page'));
      expect(decision.summary, contains('The header row renders.'));
      expect(decision.origin, DecisionOrigin.verificationRun);
      expect(decision.originId, 'v-1');
    });

    test('carries whether the verifier was the author', () {
      recordFinishedVerdict(container, run(producedBy: 's2'));
      expect(recordOf('s1').single.detail, contains('by another session'));

      recordFinishedVerdict(container, run(producedBy: 's1'));
      expect(recordOf('s1').last.detail, contains('by the author'));

      recordFinishedVerdict(container, run(producedBy: null));
      // Never folded into either neighbour: unattributed is its own state.
      expect(recordOf('s1').last.detail, contains('not recorded'));
    });

    test('a run still recording, or attached to nobody, writes nothing', () {
      recordFinishedVerdict(container, run(verdict: null));
      recordFinishedVerdict(container, run(sessionId: null));
      recordFinishedVerdict(container, null);
      expect(recordOf('s1'), isEmpty);
    });
  });
}
