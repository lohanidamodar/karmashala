/// The phone's Notes tab: the desktop's todo list and notes, read-only.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/remote.dart';

import 'companion_test_support.dart';

void main() {
  Future<FakeCompanionGateway> pump(
    WidgetTester tester,
    RemoteNotesSnapshot snapshot,
  ) async {
    final gateway = FakeCompanionGateway.paired()..notesSnapshot = snapshot;
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const Scaffold(body: NotesScreen()),
    );
    await tester.pumpAndSettle();
    return gateway;
  }

  testWidgets('todos and notes, and a note opens whole', (tester) async {
    await pump(
      tester,
      RemoteNotesSnapshot(
        todos: const [
          RemoteTodo(id: 't1', body: 'write the tests'),
          RemoteTodo(id: 't2', body: 'ship it', done: true),
        ],
        notes: [
          RemoteNote(
            id: 'n1',
            title: 'Release checklist',
            body: 'Release checklist\nbump the version',
            updatedAt: DateTime.utc(2026, 9, 24),
            projectName: 'karmashala',
            truncated: true,
          ),
        ],
      ),
    );

    expect(find.text('write the tests'), findsOneWidget);
    expect(find.text('ship it'), findsOneWidget);
    expect(find.text('Release checklist'), findsOneWidget);

    await tester.tap(find.text('Release checklist'));
    await tester.pumpAndSettle();
    expect(find.text('Release checklist\nbump the version'), findsOneWidget);
    expect(
      find.textContaining('rest of this note is on the desktop'),
      findsOneWidget,
    );
  });

  testWidgets('notes switched off on the desktop are said to be', (
    tester,
  ) async {
    await pump(
      tester,
      const RemoteNotesSnapshot(notes: [], todos: [], notesEnabled: false),
    );
    expect(find.text('Notes are switched off on the desktop.'), findsOneWidget);
    expect(find.text('Nothing on the todo list.'), findsOneWidget);
  });

  testWidgets('a desktop that cannot answer is a failure with a retry', (
    tester,
  ) async {
    final gateway = FakeCompanionGateway.paired()
      ..notesFailure = const GatewayException('this host cannot share notes');
    await pumpPhone(
      tester,
      gateway: gateway,
      home: const Scaffold(body: NotesScreen()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Try again'), findsOneWidget);
  });
}
