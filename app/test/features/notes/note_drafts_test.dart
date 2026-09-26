import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/notes/application/note_drafts.dart';
import 'package:karmashala/src/features/notes/application/notes_providers.dart';
import 'package:karmashala/src/features/notes/domain/note_draft.dart';
import 'package:karmashala/src/features/system/system_integration_service.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../system/fake_native_adapters.dart';
import 'package:karmashala_notes/store.dart';

/// The buffer a note tab edits: autosaved after a pause, never written over
/// something that changed elsewhere, and honest about which of those it is in.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.memory();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  String capture(String body, {String? title}) => container
      .read(notesProvider.notifier)
      .capture(body: body, title: title)
      .id;

  NoteDrafts drafts() => container.read(noteDraftsProvider.notifier);
  NoteDraft? draftOf(String id) => container.read(noteDraftsProvider)[id];

  testWidgets('an edit autosaves after a pause, through the DAO', (
    tester,
  ) async {
    final id = capture('first');
    drafts().open(id);
    expect(draftOf(id)!.saveState, NoteSaveState.saved);

    drafts().edit(id, body: 'first, then more');
    expect(draftOf(id)!.saveState, NoteSaveState.saving);
    expect(
      NoteDao(container.read(databaseProvider)).getById(id)!.body,
      'first',
    );

    await tester.pump(NoteDrafts.autosaveDelay ~/ 2);
    drafts().edit(id, title: 'Named');
    await tester.pump(NoteDrafts.autosaveDelay ~/ 2);
    expect(
      NoteDao(container.read(databaseProvider)).getById(id)!.body,
      'first',
      reason: 'a keystroke restarts the pause',
    );

    await tester.pump(NoteDrafts.autosaveDelay);
    final stored = NoteDao(container.read(databaseProvider)).getById(id)!;
    expect(stored.body, 'first, then more');
    expect(stored.title, 'Named');
    expect(draftOf(id)!.saveState, NoteSaveState.saved);
  });

  testWidgets('saving now writes without waiting', (tester) async {
    final id = capture('a');
    drafts()
      ..open(id)
      ..edit(id, body: 'b')
      ..save(id);
    expect(NoteDao(container.read(databaseProvider)).getById(id)!.body, 'b');
    expect(draftOf(id)!.saveState, NoteSaveState.saved);
  });

  testWidgets('a change elsewhere is adopted when nothing is unsaved', (
    tester,
  ) async {
    final id = capture('mine');
    drafts().open(id);

    container.read(notesProvider.notifier).edit(id, body: 'changed by agent');
    expect(draftOf(id)!.body, 'changed by agent');
    expect(draftOf(id)!.hasConflict, isFalse);
  });

  testWidgets('a change elsewhere under unsaved edits is a conflict, and '
      'autosave does not clobber it', (tester) async {
    final id = capture('base');
    drafts()
      ..open(id)
      ..edit(id, body: 'my unsaved words');

    container.read(notesProvider.notifier).edit(id, body: 'their words');
    expect(draftOf(id)!.hasConflict, isTrue);
    expect(draftOf(id)!.saveState, NoteSaveState.conflict);
    expect(draftOf(id)!.body, 'my unsaved words');

    await tester.pump(NoteDrafts.autosaveDelay * 3);
    expect(
      NoteDao(container.read(databaseProvider)).getById(id)!.body,
      'their words',
    );

    drafts().keepMine(id);
    expect(
      NoteDao(container.read(databaseProvider)).getById(id)!.body,
      'my unsaved words',
    );
    expect(draftOf(id)!.saveState, NoteSaveState.saved);
  });

  testWidgets('taking theirs drops the unsaved edits', (tester) async {
    final id = capture('base');
    drafts()
      ..open(id)
      ..edit(id, body: 'mine');
    container.read(notesProvider.notifier).edit(id, body: 'theirs');

    drafts().takeTheirs(id);
    expect(draftOf(id)!.body, 'theirs');
    expect(draftOf(id)!.saveState, NoteSaveState.saved);
    await tester.pump(NoteDrafts.autosaveDelay * 2);
    expect(
      NoteDao(container.read(databaseProvider)).getById(id)!.body,
      'theirs',
    );
  });

  testWidgets('releasing a draft flushes what it had not saved yet', (
    tester,
  ) async {
    final id = capture('before');
    drafts()
      ..open(id)
      ..edit(id, body: 'after')
      ..release(id);
    expect(
      NoteDao(container.read(databaseProvider)).getById(id)!.body,
      'after',
    );
    expect(draftOf(id), isNull);
    await tester.pump(NoteDrafts.autosaveDelay * 2);
  });

  testWidgets('an empty note says it will not be kept', (tester) async {
    final id = capture('');
    drafts().open(id);
    expect(draftOf(id)!.saveState, NoteSaveState.empty);
  });

  /// Quits the way the tray, Cmd+Q and the window's X all do, and reads what
  /// the store held when the ordered shutdown began — the moment after which
  /// disposing the container cancels any pending autosave.
  Future<String?> quitReading(WidgetTester tester, String id) async {
    String? atShutdown;
    final service = SystemIntegrationService(
      container,
      adapters: FakeNatives().adapters,
      registerOsQuit: (_) {},
      endProcess: () {},
      onQuitRequested: () async => atShutdown = NoteDao(
        container.read(databaseProvider),
      ).getById(id)!.body,
    );
    unawaited(service.quit());
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    return atShutdown;
  }

  testWidgets('quitting inside the autosave pause writes the last keystrokes', (
    tester,
  ) async {
    final id = capture('before');
    drafts()
      ..open(id)
      ..edit(id, body: 'typed just before quitting');

    expect(await quitReading(tester, id), 'typed just before quitting');
  });

  testWidgets('quitting does not write over a note in conflict', (
    tester,
  ) async {
    final id = capture('base');
    drafts()
      ..open(id)
      ..edit(id, body: 'mine');
    container.read(notesProvider.notifier).edit(id, body: 'theirs');

    expect(await quitReading(tester, id), 'theirs');
  });
}
