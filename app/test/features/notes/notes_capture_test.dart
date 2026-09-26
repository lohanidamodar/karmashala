import 'package:karmashala_store/database.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notes/application/composer_draft.dart';
import 'package:karmashala/src/features/notes/application/notes_providers.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import 'package:karmashala_notes/store.dart';
import 'package:karmashala/src/core/database/database_providers.dart';

/// A clock stuck at [testTime], so a captured note's timestamps are checkable.
class _FixedClock implements Clock {
  const _FixedClock();
  @override
  DateTime nowUtc() => testTime;
}

void main() {
  const messages = [
    TranscriptMessage(
      role: 'user',
      text: 'what if the tab strip had a compact mode?',
    ),
    TranscriptMessage(
      role: 'agent',
      text: 'It could reuse Chrome.row. Want me to try it?',
    ),
  ];

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    bool notesEnabled = true,
  }) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    final container = ProviderContainer(
      overrides: [
        // Fakes for everything this view pulls in that would otherwise poll a
        // process or leave a timer running past the widget tree.
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(const _FixedClock()),
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
        sessionChatTranscriptProvider(
          's1',
        ).overrideWith((ref) => Stream.value(messages)),
      ],
    );
    addTearDown(container.dispose);
    container.read(sessionDaoProvider).insert(session());
    container
        .read(settingsControllerProvider.notifier)
        .setNotesEnabled(notesEnabled);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SessionTranscriptView(sessionId: 's1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('keeping a message stores its words and where they came from', (
    tester,
  ) async {
    final container = await pump(tester);

    // Two messages, so two note buttons; keep the agent's reply (the second).
    final buttons = find.byTooltip('Save as note');
    expect(buttons, findsNWidgets(2));
    await tester.tap(buttons.last);
    await tester.pump();

    final notes = container.read(notesProvider);
    expect(notes, hasLength(1));
    final note = notes.single;
    // Quoted, not summarised: the message's own text, character for character.
    expect(note.body, 'It could reuse Chrome.row. Want me to try it?');
    expect(note.sourceSessionId, 's1');
    expect(note.sourceRepositoryId, 'r1');
    expect(note.sourceMessageRole, 'agent');
    expect(note.sourceMessageOrdinal, 1);
    expect(note.createdAt, testTime);

    // And it is in the database, not only in memory.
    expect(NoteDao(container.read(databaseProvider)).list().single.id, note.id);

    // Let the confirmation and the button's "saved" flash expire.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('the ordinal is the message index in the whole transcript', (
    tester,
  ) async {
    final container = await pump(tester);

    await tester.tap(find.byTooltip('Save as note').first);
    await tester.pump();

    final note = container.read(notesProvider).single;
    expect(note.sourceMessageOrdinal, 0);
    expect(note.sourceMessageRole, 'user');

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('the affordance is gone when Notes is switched off', (
    tester,
  ) async {
    final container = await pump(tester, notesEnabled: false);

    expect(find.byTooltip('Save as note'), findsNothing);
    // Copy is untouched — only the note button goes.
    expect(find.byTooltip('Copy message'), findsNWidgets(2));
    expect(container.read(notesProvider), isEmpty);
  });

  testWidgets('a note sent back lands in this session\'s composer, unsent', (
    tester,
  ) async {
    final container = await pump(tester);

    container
        .read(composerDraftProvider.notifier)
        .queue('s1', 'Give the tab strip a compact mode.');
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Give the tab strip a compact mode.');
    // Taken, so opening the session again does not paste it a second time.
    expect(container.read(composerDraftProvider), isEmpty);
  });

  testWidgets('an arriving note is appended to what the user was typing', (
    tester,
  ) async {
    final container = await pump(tester);

    await tester.enterText(find.byType(TextField), 'half a thought');
    container.read(composerDraftProvider.notifier).queue('s1', 'the note');
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'half a thought\n\nthe note');
  });

  testWidgets('a note queued for another session is left alone', (
    tester,
  ) async {
    final container = await pump(tester);

    container.read(composerDraftProvider.notifier).queue('s2', 'later');
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(container.read(composerDraftProvider), containsPair('s2', 'later'));
  });
}
