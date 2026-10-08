import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart'
    show RewindMarker, TranscriptMessage, kTranscriptRewindRole;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/turn_rewinds.dart';
import 'package:karmashala/src/features/sessions/data/sessions_client.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/message_composer.dart';
import 'package:karmashala/src/features/sessions/presentation/rewind_dialog.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../../support/window_matrix.dart';
import '../terminal/fake_instance.dart';

/// **Rewind to here**: offered on the person's own messages where the agent
/// can cut its conversation, a dialog with Claude Code's three modes and what
/// each changes, the server's rewind, the person's words back in the box, and
/// the undone turns kept, folded and dimmed.
void main() {
  final t0 = DateTime.utc(2026, 10, 8, 9);
  DateTime at(int minutes) => t0.add(Duration(minutes: minutes));

  final history = [
    ChatMessage(role: 'user', text: 'Make it blue', at: at(0)),
    ChatMessage(role: 'agent', text: 'Blue now.', at: at(1)),
    ChatMessage(role: 'user', text: 'Now make it red', at: at(2)),
    ChatMessage(role: 'agent', text: 'Red now.', at: at(3)),
    ChatMessage(role: 'user', text: 'And green', at: at(4)),
    ChatMessage(role: 'agent', text: 'Green now.', at: at(5)),
  ];
  const marker = RewindMarker(turns: 2, mode: RewindMode.both);
  final rewound = [
    ...history,
    ChatMessage(role: kTranscriptRewindRole, text: marker.text, at: at(6)),
    ChatMessage(role: 'user', text: 'Make it purple', at: at(7)),
    ChatMessage(role: 'agent', text: 'Purple now.', at: at(8)),
  ];

  group('in the transcript', () {
    late List<TurnRewindTarget> asked;
    setUp(() => asked = []);

    Widget view(
      List<ChatMessage> messages, {
      bool rewinds = true,
      String? busy,
      bool touch = false,
    }) => MaterialApp(
      home: UiDensityScope(
        density: touch ? UiDensity.touch : UiDensity.pointer,
        child: Scaffold(
          body: ChatTranscriptView(
            messages: messages,
            turn: TranscriptTurn.idle,
            turnActions: TranscriptTurnActions(
              onRewind: rewinds ? asked.add : null,
              busy: busy,
              forkPoints: const {
                2: TurnForkPoints(before: TurnForkTarget.turn(4)),
              },
            ),
          ),
        ),
      ),
    );

    IconButton button(WidgetTester tester, int at) => tester.widget<IconButton>(
      find.byKey(const ValueKey('chat-turn-rewind')).at(at),
    );

    testWidgets('a session that can rewind offers it on the person\'s rows '
        'only, with the message\'s place, words and checkpoint', (
      tester,
    ) async {
      await tester.pumpWidget(view(history));
      expect(find.byKey(const ValueKey('chat-turn-rewind')), findsNWidgets(3));
      await tester.tap(find.byKey(const ValueKey('chat-turn-rewind')).at(1));
      await tester.pump();
      expect(asked, const [
        TurnRewindTarget(
          turnIndex: 1,
          words: 'Now make it red',
          before: TurnForkTarget.turn(4),
        ),
      ]);
    });

    testWidgets('one that cannot offers nothing', (tester) async {
      await tester.pumpWidget(view(history, rewinds: false));
      expect(find.byKey(const ValueKey('chat-turn-rewind')), findsNothing);
    });

    testWidgets('it waits while the agent works, saying to stop it first', (
      tester,
    ) async {
      await tester.pumpWidget(view(history, busy: 'A turn is running.'));
      expect(button(tester, 0).onPressed, isNull);
      expect(button(tester, 0).tooltip, contains(kRewindWhileWorking));
    });

    testWidgets('rewound turns are kept, folded under their count, and open '
        'dimmed; their rewind is refused', (tester) async {
      await tester.pumpWidget(view(rewound));
      expect(find.text('Make it blue'), findsOneWidget);
      expect(find.text('Now make it red'), findsNothing);
      expect(find.text('Green now.'), findsNothing);
      expect(find.text('Make it purple'), findsOneWidget);
      expect(
        find.textContaining('Rewound · 2 turns · Code and conversation'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('chat-rewound-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('Now make it red'), findsOneWidget);
      expect(find.text('Green now.'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.text('Now make it red'),
          matching: find.byWidgetPredicate(
            (w) => w is Opacity && w.opacity == StateLayers.rewoundOpacity,
          ),
        ),
        findsOneWidget,
      );
      // Rows: blue, red (rewound), green (rewound), purple.
      expect(button(tester, 1).onPressed, isNull);
      expect(button(tester, 1).tooltip, contains('already rewound'));
      expect(button(tester, 3).onPressed, isNotNull);
    });

    test('Copy turn marks a rewound turn', () {
      expect(
        transcriptTurnMarkdown(rewound, 2),
        startsWith('_Rewound: this turn was undone._'),
      );
      expect(transcriptTurnMarkdown(rewound, 0), startsWith('### You'));
    });

    testWidgets('folded turns fit 360 px at text 1.6 and a desktop', (
      tester,
    ) async {
      for (final touch in [false, true]) {
        await expectSurvivesWindowMatrix(
          tester,
          because: 'a fold\'s header shares the transcript\'s width',
          matrix: const [
            WindowCell(
              '360x760 phone, text 1.6',
              Size(360, 760),
              textScale: 1.6,
            ),
            desktopWindow,
          ],
          build: () => view(rewound, touch: touch),
        );
      }
    });
  });

  group('the dialog', () {
    const preview = RewindPreview(
      turns: 3,
      files: 5,
      outside: ['README.md', 'lib/a.dart'],
      headMoved: false,
      refusals: [],
      note: 'Claude Code restarts remembering only what came before.',
    );

    Future<RewindChoice?> open(
      WidgetTester tester, {
      TurnRewindTarget target = const TurnRewindTarget(
        turnIndex: 1,
        words: 'Now make it red',
        before: TurnForkTarget.turn(4),
      ),
      RewindPreview answer = preview,
      List<RewindMode>? previewed,
    }) async {
      RewindChoice? choice;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => choice = await RewindDialog.show(
                context,
                target: target,
                preview: (mode) async {
                  previewed?.add(mode);
                  return answer;
                },
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return choice;
    }

    String summary(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const ValueKey('rewind-summary'))).data!;

    testWidgets('three modes, code and conversation first, each saying what '
        'it changes', (tester) async {
      final previewed = <RewindMode>[];
      await open(tester, previewed: previewed);
      expect(previewed, [RewindMode.both]);
      expect(find.text('Rewind to before this message'), findsOneWidget);
      expect(find.text('“Now make it red”'), findsOneWidget);
      expect(summary(tester), '3 turns will be undone · 5 files restored');

      await tester.tap(find.text('Conversation only'));
      await tester.pumpAndSettle();
      expect(summary(tester), '3 turns will be undone');
      expect(find.byKey(const ValueKey('rewind-outside')), findsNothing);

      await tester.tap(find.text('Code only'));
      await tester.pumpAndSettle();
      expect(summary(tester), '5 files restored · the conversation stays');
      expect(find.textContaining('still believes'), findsOneWidget);
    });

    testWidgets('files changed outside the agent are named, and the rewind '
        'then confirms', (tester) async {
      RewindChoice? choice;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => choice = await RewindDialog.show(
                context,
                target: const TurnRewindTarget(
                  turnIndex: 1,
                  words: 'Now make it red',
                  before: TurnForkTarget.turn(4),
                ),
                preview: (_) async => preview,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('README.md, lib/a.dart'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('rewind-confirm')));
      await tester.pumpAndSettle();
      expect(choice, (mode: RewindMode.both, confirm: true));
    });

    testWidgets('with no checkpoint only the conversation can go back', (
      tester,
    ) async {
      final previewed = <RewindMode>[];
      await open(
        tester,
        target: const TurnRewindTarget(turnIndex: 0, words: 'Make it blue'),
        answer: const RewindPreview(
          turns: 3,
          files: 0,
          outside: [],
          headMoved: false,
          refusals: [],
          note: '',
        ),
        previewed: previewed,
      );
      expect(previewed, [RewindMode.conversation]);
      final code = tester.widget<RadioListTile<RewindMode>>(
        find.byKey(const ValueKey('rewind-mode-code')),
      );
      expect(code.enabled, isFalse);
      expect(find.textContaining('No checkpoint'), findsNWidgets(2));
      expect(summary(tester), '3 turns will be undone');
    });

    testWidgets('fits 360 px at text 1.6 and a desktop', (tester) async {
      await expectSurvivesWindowMatrix(
        tester,
        because: 'the dialog names files and three modes',
        matrix: const [
          WindowCell('360x760 phone, text 1.6', Size(360, 760), textScale: 1.6),
          desktopWindow,
        ],
        build: () => MaterialApp(
          home: Scaffold(
            body: RewindDialog(
              target: const TurnRewindTarget(
                turnIndex: 1,
                words: 'Now make it red, and keep the borders as they are',
                before: TurnForkTarget.turn(4),
              ),
              preview: (_) async => preview,
            ),
          ),
        ),
      );
    });
  });

  test('the request names the checkpoint only for the modes that restore '
      'files', () async {
    final client = _FakeSessions();
    final rewinds = TurnRewinds(client);
    const target = TurnRewindTarget(
      turnIndex: 2,
      words: 'And green',
      before: TurnForkTarget.turn(5),
    );
    final preview = await rewinds.preview('s1', target, RewindMode.both);
    expect(client.asked.single.preview, isTrue);
    expect(client.asked.single.checkpointTurn, 5);
    expect(preview.turns, 2);
    expect(preview.outside, ['x.md']);

    await rewinds.rewind('s1', target, RewindMode.conversation, confirm: true);
    expect(client.asked.last.mode, 'conversation');
    expect(client.asked.last.checkpointTurn, isNull);
    expect(client.asked.last.confirm, isTrue);
  });

  group('in the chat', () {
    late TestMachine db;
    late FakeDataServer server;

    final said = [
      TranscriptMessage(role: 'user', text: 'Make it blue', at: at(0)),
      TranscriptMessage(role: 'agent', text: 'Blue now.', at: at(1)),
      TranscriptMessage(role: 'user', text: 'Now make it red', at: at(2)),
      TranscriptMessage(role: 'agent', text: 'Red now.', at: at(3)),
    ];

    setUp(() async {
      db = TestMachine();
      server = FakeDataServer()..runsOn(db);
      server.environmentRows.upsert(windowsEnv());
      server.projectRows.insert(project());
      server.repositoryRows.insert(repository());
      server.installationRows
        ..insert(
          agentInstallation(
            id: 'acp',
            agentId: AgentIds.claudeAcp,
            path: r'C:\Users\me\.local\bin\claude.exe',
          ),
        )
        ..insert(
          agentInstallation(
            id: 'cx',
            agentId: AgentIds.codex,
            path: r'C:\Users\me\.bin\codex.exe',
          ),
        );
      server.sessionWork.running.add('s1');
      db.server.sessionRows.insert(
        session(
          id: 's1',
          agentInstallationId: 'acp',
          status: SessionStatus.running,
        ),
      );
    });

    Future<void> pump(
      WidgetTester tester, {
      Size size = const Size(1440, 900),
      bool offered = true,
      AgentActivityStatus activity = AgentActivityStatus.idle,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = ProviderContainer(
        overrides: [
          await server.override(),
          ...fakeTerminalOverrides(machine: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          serverOfferProvider.overrideWithValue(
            ServerOffer(
              sameMachine: true,
              serverOs: 'windows',
              features: {
                'sessions.send',
                'sessions.interrupt',
                if (offered) 'sessions.rewind',
              },
            ),
          ),
          sessionRunningOnHostProvider.overrideWithValue((_) => true),
          sessionActivityLookupProvider.overrideWithValue((_) => activity),
          sessionChatTranscriptProvider.overrideWith(
            (ref, id) => Stream.value(said),
          ),
          availableSystemTerminalsProvider.overrideWith(
            (ref) async => const <SystemTerminal>[],
          ),
          sessionDeliveryProvider.overrideWith(
            (ref, _) async => SessionDelivery.unknown,
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: SessionTranscriptView(sessionId: 's1')),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    String composerText(WidgetTester tester) => tester
        .widget<TextField>(
          find
              .descendant(
                of: find.byType(MessageComposer),
                matching: find.byType(TextField),
              )
              .last,
        )
        .controller!
        .text;

    for (final (name, size) in [
      ('phone', const Size(390, 844)),
      ('desktop', const Size(1440, 900)),
    ]) {
      testWidgets('on a $name the conversation is rewound by the server and '
          'the message goes back in the box', (tester) async {
        server.sessionWork.rewindPreview = const {
          'preview': true,
          'turns': 1,
          'files': 0,
          'conversation': {'note': 'Claude Code forgets it.'},
        };
        server.sessionWork.rewindAnswer = const {
          'rewound': true,
          'turns': 1,
          'files': 0,
          'composerText': 'Now make it red',
        };
        await pump(tester, size: size);
        final rewind = find.byKey(const ValueKey('chat-turn-rewind'));
        if (rewind.evaluate().isEmpty) {
          // Touch: the turn's actions are behind ⋯ once it is tapped.
          await tester.tap(find.text('Now make it red'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('chat-turn-more')).last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Rewind to here…'));
        } else {
          await tester.tap(rewind.last);
        }
        await tester.pumpAndSettle();
        expect(find.text('Rewind to before this message'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('rewind-confirm')));
        await tester.pumpAndSettle();

        final asked = server.sessionWork.rewinds;
        expect(asked.first.preview, isTrue);
        expect(asked.last.preview, isFalse);
        expect(asked.last.mode, 'conversation');
        expect(asked.last.turnIndex, 1);
        expect(asked.last.words, 'Now make it red');
        expect(composerText(tester), 'Now make it red');
        expect(find.textContaining('1 turn undone'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a server that cannot rewind offers nothing', (tester) async {
      await pump(tester, offered: false);
      expect(find.byKey(const ValueKey('chat-turn-rewind')), findsNothing);
    });

    testWidgets('an agent that cannot cut its conversation offers nothing', (
      tester,
    ) async {
      final row = db.server.sessionRows.getById('s1')!;
      db.server.sessionRows.put(row.copyWith(agentInstallationId: 'cx'));
      await pump(tester);
      expect(find.byKey(const ValueKey('chat-turn-rewind')), findsNothing);
    });

    testWidgets('a refusal is said, and the box is left alone', (tester) async {
      server.sessionWork.rewindRefusesWith = kRewindWhileWorking;
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('chat-turn-rewind')).last);
      await tester.pumpAndSettle();
      expect(find.textContaining(kRewindWhileWorking), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(composerText(tester), isEmpty);
    });
  });
}

class _FakeSessions implements SessionsClient {
  final asked = <SessionRewind>[];

  @override
  Future<Map<String, Object?>> rewind(SessionRewind request) async {
    asked.add(request);
    return {
      'preview': request.preview,
      'turns': 2,
      'files': 1,
      'outside': ['x.md'],
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
