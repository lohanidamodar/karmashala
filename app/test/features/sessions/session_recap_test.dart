import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/session_model_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_view_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_recap_service.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/transcript.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/sessions/presentation/session_recap_card.dart';

import '../terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/workspace_mirror.dart';
import '../../support/temp_directory.dart';

void main() {
  group('the request', () {
    test('is one fixed prompt, in the shape the decision asked for', () {
      final concluded = kSessionRecapRequest.indexOf('Concluded');
      final left = kSessionRecapRequest.indexOf('Left');
      final doNot = kSessionRecapRequest.indexOf('Do not');
      expect(concluded, greaterThan(-1));
      expect(left, greaterThan(concluded));
      expect(doNot, greaterThan(left));
      // The §19 clause: a heading with nothing under it is answered, not
      // filled in.
      expect(kSessionRecapRequest, contains('rather than inventing one'));
    });

    test('is the same prompt whichever CLI is asked', () async {
      for (final agentId in [
        AgentIds.claudeCode,
        AgentIds.codex,
        AgentIds.antigravity,
      ]) {
        final h = await harness(
          agentId: agentId,
          transcript: _transcript(agentId: agentId),
        );
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);
        await h.container.read(sessionRecapServiceProvider).write('s1');
        // Claude and Codex carry the request alone; Antigravity carries it with
        // the conversation appended, so it is the prefix either way — and it is
        // the same prefix for all three.
        expect(
          h.runner.requests.single.arguments.last,
          startsWith(kSessionRecapRequest),
          reason: agentId,
        );
      }
    });
  });

  group('the command each CLI is asked with', () {
    test('Claude Code: `claude -p <prompt>`, conversation on stdin', () async {
      final h = await harness(
        agentId: AgentIds.claudeCode,
        transcript: _transcript(),
      );
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      await h.container.read(sessionRecapServiceProvider).write('s1');

      final request = h.runner.requests.single;
      expect(request.executable, r'C:\Users\me\.bin\claude.exe');
      expect(request.arguments, ['-p', kSessionRecapRequest]);
      expect(request.stdinText, contains('what did we settle'));
      expect(request.stdinText, contains('we settled on B'));
    });

    test('Codex: `codex exec <prompt>`, conversation on stdin', () async {
      final h = await harness(
        agentId: AgentIds.codex,
        transcript: _transcript(agentId: AgentIds.codex),
      );
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      await h.container.read(sessionRecapServiceProvider).write('s1');

      final request = h.runner.requests.single;
      expect(request.arguments, ['exec', kSessionRecapRequest]);
      expect(request.stdinText, contains('we settled on B'));
    });

    test('Antigravity: `agy --print`, conversation in the prompt', () async {
      final h = await harness(
        agentId: AgentIds.antigravity,
        transcript: _transcript(agentId: AgentIds.antigravity),
      );
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      await h.container.read(sessionRecapServiceProvider).write('s1');

      final request = h.runner.requests.single;
      expect(request.arguments.first, '--print');
      expect(request.arguments, hasLength(2));
      // The whole document rides in the argument, because this CLI reads no
      // conversation from anywhere else — and nothing is written to a stdin it
      // does not read.
      expect(request.arguments.last, startsWith(kSessionRecapRequest));
      expect(request.arguments.last, contains('we settled on B'));
      expect(request.stdinText, isNull);
    });

    test('the model is asked for, and stored as what was asked', () async {
      final h = await harness(
        agentId: AgentIds.claudeCode,
        transcript: _transcript(),
        model: 'haiku',
      );
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      await h.container.read(sessionRecapServiceProvider).write('s1');

      expect(h.runner.requests.single.arguments, [
        '-p',
        '--model',
        'haiku',
        kSessionRecapRequest,
      ]);
      expect(
        h.container.read(sessionRecapDaoProvider).forSession('s1')!.model,
        'haiku',
      );
    });

    test(
      'a conversation too long for the wire says so in its own text',
      () async {
        final h = await harness(
          agentId: AgentIds.claudeCode,
          transcript: _transcript(padTurns: 60, padBytes: 2000),
        );
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);

        await h.container.read(sessionRecapServiceProvider).write('s1');

        final blob = h.runner.requests.single.stdinText!;
        expect(
          utf8.encode(blob).length,
          lessThanOrEqualTo(kMaxTranscriptTextBytes),
        );
        expect(blob, startsWith('[The earliest'));
        // Fitted from the end: a recap is asked for by somebody returning to the
        // conversation, and the end is what they are returning to.
        expect(blob, contains('we settled on B'));
      },
    );
  });

  group('nothing produces a recap but the action', () {
    test('a launch, an end and a restore spawn nothing', () async {
      final h = await harness(
        agentId: AgentIds.claudeCode,
        transcript: _transcript(),
      );
      addTearDown(h.db.close);

      // Launch: the row exists and every surface that would show a recap is
      // read.
      expect(h.container.read(sessionRecapProvider('s1')), isNull);
      await h.container.read(sessionChatViewProbeProvider('s1').future);

      // End.
      h.container
          .read(sessionDaoProvider)
          .updateStatus('s1', SessionStatus.completed);
      expect(h.container.read(sessionRecapProvider('s1')), isNull);
      h.container.dispose();

      // Restore: a fresh container over the same database, exactly as a
      // relaunch reads it.
      final again = await harness(
        agentId: AgentIds.claudeCode,
        transcript: _transcript(),
        db: h.db,
        runner: h.runner,
      );
      addTearDown(again.container.dispose);
      expect(again.container.read(sessionRecapProvider('s1')), isNull);

      expect(h.runner.requests, isEmpty);
      expect(h.runner.startRequests, isEmpty);
    });

    test('only the action reaches the service', () {
      final callers = <String>[];
      for (final file
          in Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))) {
        if (file.readAsStringSync().contains('sessionRecapServiceProvider')) {
          callers.add(file.uri.pathSegments.last);
        }
      }
      // The service declares it; `requestSessionRecap` is the only caller, and
      // it is what every surface goes through.
      expect(callers.toSet(), {
        'session_recap_service.dart',
        'session_recap_card.dart',
      });
    });
  });

  group('a session with no readable transcript', () {
    test('refuses in the chat view reading own words', () async {
      final h = await harness(
        agentId: AgentIds.claudeCode,
        transcript: null,
        chatView: const SessionChatView.read(
          ChatViewEvidence.transcriptAbsent,
          prior: true,
        ),
      );
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      await expectLater(
        h.container.read(sessionRecapServiceProvider).write('s1'),
        throwsA(
          isA<SessionRecapRefusal>().having(
            (r) => r.reason,
            'reason',
            contains(
              const SessionChatView.read(
                ChatViewEvidence.transcriptAbsent,
                prior: true,
              ).reason,
            ),
          ),
        ),
      );
      expect(h.runner.requests, isEmpty);
    });
  });

  group('the card', () {
    testWidgets('renders the stored row with the age of the reading', (
      tester,
    ) async {
      final db = _seededDb();
      addTearDown(db.close);
      SessionRecapDaoWriter.seed(
        db,
        turnCount: 4,
        writtenAt: testTime.subtract(const Duration(hours: 3)),
      );

      await tester.pumpWidget(await _card(db: db, turnsNow: 4));
      await tester.pump();

      expect(find.text('Recap'), findsOneWidget);
      expect(find.textContaining('Concluded: we settled on B'), findsOneWidget);
      expect(
        find.textContaining(
          'Written by Claude Code (haiku) 3h ago, over 4 turns',
        ),
        findsOneWidget,
      );
      expect(find.text('Recap again'), findsNothing);
    });

    testWidgets('says so, and offers Recap again, once the session has moved', (
      tester,
    ) async {
      final db = _seededDb();
      addTearDown(db.close);
      SessionRecapDaoWriter.seed(db, turnCount: 4, writtenAt: testTime);

      await tester.pumpWidget(await _card(db: db, turnsNow: 9));
      await tester.pump();

      expect(
        find.textContaining('the session has moved since — 5 more turns'),
        findsOneWidget,
      );
      expect(find.text('Recap again'), findsOneWidget);
    });

    testWidgets('draws nothing at all before anybody asks', (tester) async {
      final db = _seededDb();
      addTearDown(db.close);

      await tester.pumpWidget(await _card(db: db, turnsNow: 4));
      await tester.pump();

      expect(find.text('Recap'), findsNothing);
    });
  });
}

// --- harness -----------------------------------------------------------------

typedef RecapHarness = ({
  ProviderContainer container,
  AppDatabase db,
  FakeCommandRunner runner,
});

Future<RecapHarness> harness({
  required String agentId,
  required String? transcript,
  String? model,
  SessionChatView chatView = const SessionChatView.read(
    ChatViewEvidence.transcriptOnDisk,
    prior: true,
  ),
  AppDatabase? db,
  FakeCommandRunner? runner,
}) async {
  final database = db ?? _seededDb(agentId: agentId);
  final fake =
      runner ??
      FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 0,
          stdout: 'Concluded: we settled on B\nLeft: nothing\nDo not: A',
          stderr: '',
        ),
      );

  final container = ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(database: database),
      await _serverOf[database]!.override(),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      commandRunnerFactoryProvider.overrideWithValue(
        FakeCommandRunnerFactory(fallback: fake),
      ),
      hostCommandRunnerProvider.overrideWithValue(fake),
      sessionTranscriptLocatorProvider.overrideWithValue(
        _FakeLocator(transcript),
      ),
      sessionChatViewProbeProvider.overrideWith((ref, id) async => chatView),
      // Resolved by the launcher in the app; pinned here so the assertion is
      // about what the recap does with a model, not about how one is chosen.
      sessionModelProvider.overrideWith(
        (ref, sessionId) => model == null
            ? null
            : SessionModelState(
                sessionId: sessionId,
                descriptor: AgentRegistry.builtIn.byId(agentId),
                modelId: model,
                defaultModelId: null,
                inherited: false,
              ),
      ),
    ],
  );
  return (container: container, db: database, runner: fake);
}

/// The server each seeded database's workspace lives at.
final _serverOf = Expando<FakeDataServer>();

AppDatabase _seededDb({String agentId = AgentIds.claudeCode}) {
  final db = AppDatabase.memory();
  final server = _serverOf[db] = FakeDataServer()..mirrorInto(db);
  ExecutionEnvironmentDao(db).upsert(windowsEnv());
  server.projectRows.insert(project());
  server.repositoryRows.insert(repository());
  AgentInstallationDao(
    db,
  ).insert(agentInstallation(id: 'a1', agentId: agentId));
  SessionDao(db).insert(session(id: 's1').copyWith(externalSessionId: 'cli-1'));
  return db;
}

/// A transcript on disk **in the CLI's own shape**, so the real reader parses
/// it. Three shapes rather than one, because a recap reads the same file the
/// conversation does and a Claude-shaped fixture would have made two of these
/// three tests pass over an empty list.
String _transcript({
  String agentId = AgentIds.claudeCode,
  int padTurns = 0,
  int padBytes = 0,
}) {
  final dir = Directory.systemTemp.createTempSync('recap-test');
  addTearDown(() => removeTempDirectory(dir));
  final turns = <(String, String)>[
    for (var i = 0; i < padTurns; i++) ('agent', 'x' * padBytes),
    ('user', 'what did we settle on?'),
    ('agent', 'we settled on B'),
  ];
  final file = File('${dir.path}/session.jsonl');
  file.writeAsStringSync(turns.map((t) => _line(agentId, t)).join('\n'));
  return file.path;
}

String _line(String agentId, (String, String) turn) => switch (agentId) {
  AgentIds.codex => jsonEncode({
    'payload': {'type': 'message', 'role': turn.$1, 'content': turn.$2},
  }),
  AgentIds.antigravity => jsonEncode({
    'type': turn.$1 == 'user' ? 'USER_INPUT' : 'PLANNER_RESPONSE',
    'content': turn.$2,
  }),
  _ => jsonEncode({
    'type': turn.$1 == 'user' ? 'user' : 'assistant',
    'message': {
      'content': [
        {'type': 'text', 'text': turn.$2},
      ],
    },
  }),
};

class _FakeLocator implements SessionTranscriptLocator {
  _FakeLocator(this.path);
  final String? path;

  @override
  Future<String?> locate({
    required String agentId,
    required String externalSessionId,
  }) async => path;

  @override
  Future<Map<String, String>> index() async =>
      path == null ? const {} : {'claudeCode/cli-1': path!};
}

/// Writes a recap straight into the store, so the card's tests are about what
/// it renders rather than about how a row got there.
abstract final class SessionRecapDaoWriter {
  static void seed(
    AppDatabase db, {
    required int turnCount,
    required DateTime writtenAt,
  }) {
    final container = ProviderContainer(
      overrides: [...fakeTerminalOverrides(database: db)],
    );
    addTearDown(container.dispose);
    container
        .read(sessionRecapDaoProvider)
        .write(
          SessionRecap(
            sessionId: 's1',
            text: 'Concluded: we settled on B\nLeft: nothing\nDo not: A',
            agentId: AgentIds.claudeCode,
            model: 'haiku',
            turnCount: turnCount,
            writtenAt: writtenAt,
          ),
        );
  }
}

Future<Widget> _card({required AppDatabase db, required int turnsNow}) async =>
    ProviderScope(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        await _serverOf[db]!.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        sessionChatTranscriptProvider.overrideWith(
          (ref, id) => Stream.value([
            for (var i = 0; i < turnsNow; i++)
              const TranscriptMessage(role: 'agent', text: 'x'),
          ]),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: SessionRecapCard(sessionId: 's1')),
      ),
    );
