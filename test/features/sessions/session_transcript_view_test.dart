import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/features/sessions/application/session_ui_providers.dart';
import 'package:chitragupta/src/features/sessions/domain/session_event.dart';
import 'package:chitragupta/src/features/sessions/domain/session_event_types.dart';
import 'package:chitragupta/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  testWidgets('renders user and agent messages from the transcript', (
    tester,
  ) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);

    final events = [
      SessionEvent(
        id: 1,
        sessionId: 's1',
        seq: 0,
        type: SessionEventTypes.userMessage,
        payload: '{"text":"hello"}',
        createdAt: testTime,
      ),
      SessionEvent(
        id: 2,
        sessionId: 's1',
        seq: 1,
        type: SessionEventTypes.agentMessage,
        payload: '{"text":"Echo: hello"}',
        createdAt: testTime,
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sessionTranscriptProvider.overrideWith((ref) => Stream.value(events)),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SessionTranscriptView(sessionId: 's1')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Message bodies render as selectable text, CLI-style.
    expect(_selectable('hello'), findsOneWidget);
    expect(_selectable('Echo: hello'), findsOneWidget);
    // Role eyebrows are uppercased.
    expect(find.text('YOU'), findsOneWidget);
    expect(find.text('AGENT'), findsOneWidget);
    // Not active -> input is disabled with the idle hint.
    expect(find.text('Session is not running'), findsOneWidget);
  });
}

Finder _selectable(String text) =>
    find.byWidgetPredicate((w) => w is SelectableText && w.data == text);
