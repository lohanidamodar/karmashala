import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// A live transcript is re-read whole on every poll, so every tick hands the
/// view a new list of new, equal messages. Only the row that changed may build.
void main() {
  /// A fresh copy each call: the poll re-parses, it never reuses an object.
  List<ChatMessage> conversation(int turns, {String last = 'turn'}) => [
    for (var i = 0; i < turns; i++)
      ChatMessage(
        role: i.isEven ? 'user' : 'agent',
        text: i == turns - 1 ? '$last $i' : 'turn $i',
      ),
  ];

  void roomy(WidgetTester tester) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 2400);
    addTearDown(tester.view.reset);
  }

  group('ChatTranscriptView', () {
    Widget view(List<ChatMessage> messages) => MaterialApp(
      home: Scaffold(
        body: ChatTranscriptView(
          messages: messages,
          onSaveNote: _noteSink,
          onPathTap: _pathSink,
        ),
      ),
    );

    testWidgets('an appended message builds only itself', (tester) async {
      roomy(tester);
      await tester.pumpWidget(view(conversation(6)));
      await tester.pumpAndSettle();
      expect(find.textContaining('turn 5', findRichText: true), findsWidgets);

      ChatTranscriptView.debugMessageBuildCount = 0;
      await tester.pumpWidget(view(conversation(7)));
      await tester.pumpAndSettle();

      expect(find.textContaining('turn 6', findRichText: true), findsWidgets);
      expect(ChatTranscriptView.debugMessageBuildCount, 1);
    });

    testWidgets('a streaming last message rebuilds only the last row', (
      tester,
    ) async {
      roomy(tester);
      await tester.pumpWidget(view(conversation(6, last: 'partial')));
      await tester.pumpAndSettle();

      ChatTranscriptView.debugMessageBuildCount = 0;
      await tester.pumpWidget(view(conversation(6, last: 'partial and more')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('partial and more 5', findRichText: true),
        findsWidgets,
      );
      expect(ChatTranscriptView.debugMessageBuildCount, 1);
    });

    testWidgets('an unchanged re-read builds nothing', (tester) async {
      roomy(tester);
      await tester.pumpWidget(view(conversation(6)));
      await tester.pumpAndSettle();

      ChatTranscriptView.debugMessageBuildCount = 0;
      await tester.pumpWidget(view(conversation(6)));
      await tester.pumpAndSettle();

      expect(ChatTranscriptView.debugMessageBuildCount, 0);
    });

    testWidgets('loading earlier turns keeps the rows it already drew', (
      tester,
    ) async {
      // Short enough that the first page scrolls: board N2's rows have no
      // name line, and forty of them fit a roomy window whole.
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1200, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(view(conversation(45)));
      await tester.pumpAndSettle();

      // Reaching the top loads the older page, which shifts every row's
      // index; the rows keyed by ordinal still find their own elements.
      await tester.dragUntilVisible(
        find.textContaining('turn 0', findRichText: true),
        find.byKey(const ValueKey('chat-transcript-list')),
        const Offset(0, 600),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('turn 0', findRichText: true), findsWidgets);
    });
  });

  testWidgets('a poll of the session view builds only the new row', (
    tester,
  ) async {
    roomy(tester);
    final polls = StreamController<List<TranscriptMessage>>();
    addTearDown(polls.close);

    final db = TestMachine();
    final server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
    db.server.sessionRows.insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Session',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: testTime,
        surface: SessionSurface.pane,
        externalSessionId: 'ext-1',
      ),
    );

    List<TranscriptMessage> read(int turns) => [
      for (var i = 0; i < turns; i++)
        TranscriptMessage(role: i.isEven ? 'user' : 'agent', text: 'turn $i'),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...fakeTerminalOverrides(machine: db),
          await server.override(),
          availableSystemTerminalsProvider.overrideWith(
            (ref) async => const <SystemTerminal>[],
          ),
          sessionDeliveryProvider.overrideWith(
            (ref, _) async => SessionDelivery.unknown,
          ),
          agentSessionStatusProvider.overrideWith(
            (ref, id) => Stream.value(
              AgentStatusReport(
                agentId: AgentIds.claudeCode,
                sessionId: id,
                status: AgentActivityStatus.idle,
                observedAt: testTime,
                source: AgentStatusSource.none,
              ),
            ),
          ),
          sessionChatTranscriptProvider.overrideWith((ref, id) => polls.stream),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SessionTranscriptView(sessionId: 's1')),
        ),
      ),
    );
    polls.add(read(6));
    await tester.pumpAndSettle();
    expect(find.textContaining('turn 5', findRichText: true), findsWidgets);

    ChatTranscriptView.debugMessageBuildCount = 0;
    polls.add(read(7));
    await tester.pumpAndSettle();

    expect(find.textContaining('turn 6', findRichText: true), findsWidgets);
    expect(ChatTranscriptView.debugMessageBuildCount, 1);
  });
}

void _noteSink(ChatMessage message, int ordinal) {}

void _pathSink(String path) {}
