import 'dart:io';

import 'package:karmashala_host/src/sessions/launch/session_handoffs.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Nothing a launch hands over outlives its use: temp folders go when used,
/// with their session, or a day on; rows a day after use; and the files
/// launches wrote under the data folder before this go on the first start.
void main() {
  late AppDatabase database;
  late Directory temp;
  late Directory legacy;
  late SessionHandoffs handoffs;
  late DateTime clock;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('session_handoffs');
    legacy = Directory(p.join(temp.path, 'data', 'handoff'));
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    clock = DateTime.utc(2026, 10, 4, 12);
    handoffs = SessionHandoffs(
      dao: SessionHandoffDao(database),
      root: Directory(p.join(temp.path, 'root')),
      now: () => clock,
      legacy: legacy,
    );
  });

  tearDown(() {
    database.close();
    temp.deleteSync(recursive: true);
  });

  SessionHandoff? row(String id, HandoffKind kind) =>
      SessionHandoffDao(database).get(id, kind);

  test('each data folder has a temp root of its own', () {
    final a = SessionHandoffs.rootFor(r'C:\Users\me\.karmashala');
    final b = SessionHandoffs.rootFor(r'C:\Temp\karmashala-probe');
    expect(a.path, isNot(b.path));
    expect(p.isWithin(Directory.systemTemp.path, a.path), isTrue);
    expect(SessionHandoffs.rootFor(r'C:\Users\me\.karmashala').path, a.path);
  });

  test('consuming one kind deletes its file and leaves the other', () {
    final opening = handoffs.writeFile('s1', HandoffKind.opening, 'a')!;
    final system = handoffs.writeFile('s1', HandoffKind.systemPrompt, 'b')!;
    handoffs.record('s1', HandoffKind.opening, 'a', HandoffRoute.file);
    handoffs.record('s1', HandoffKind.systemPrompt, 'b', HandoffRoute.file);
    handoffs.consume('s1', kind: HandoffKind.systemPrompt);
    expect(File(system).existsSync(), isFalse);
    expect(File(opening).existsSync(), isTrue);
    handoffs.consume('s1', kind: HandoffKind.opening);
    expect(handoffs.folderOf('s1').existsSync(), isFalse);
  });

  group('sweep', () {
    test('deletes a row a day after it was used', () {
      handoffs.record('s1', HandoffKind.opening, 'a', HandoffRoute.argv);
      clock = clock.add(const Duration(hours: 23));
      handoffs.sweep(live: const {});
      expect(row('s1', HandoffKind.opening), isNotNull);
      clock = clock.add(const Duration(hours: 2));
      handoffs.sweep(live: const {});
      expect(row('s1', HandoffKind.opening), isNull);
    });

    test('keeps a waiting file of a live session, and drops a folder with '
        'nothing left to use', () {
      handoffs.writeFile('live', HandoffKind.opening, 'a');
      handoffs.record('live', HandoffKind.opening, 'a', HandoffRoute.file);
      handoffs.writeFile('stray', HandoffKind.opening, 'b');
      handoffs.sweep(live: const {'live'});
      expect(handoffs.folderOf('live').existsSync(), isTrue);
      expect(handoffs.folderOf('stray').existsSync(), isFalse);
    });

    test('drops a waiting file and row of a session not live once a day '
        'old', () {
      handoffs.writeFile('gone', HandoffKind.opening, 'a');
      handoffs.record('gone', HandoffKind.opening, 'a', HandoffRoute.file);
      handoffs.sweep(live: const {});
      // Not a day old yet: its session may still be starting.
      expect(handoffs.folderOf('gone').existsSync(), isTrue);
      clock = clock.add(const Duration(days: 2));
      handoffs.sweep(live: const {});
      expect(row('gone', HandoffKind.opening), isNull);
      expect(handoffs.folderOf('gone').existsSync(), isFalse);
    });
  });

  group('the files launches wrote before', () {
    File old(String name) =>
        File(p.join(legacy.path, name))
          ..createSync(recursive: true)
          ..writeAsStringSync('x');

    test('are swept for every session not live, the folder with them', () {
      old('prompt-gone.md');
      old('handoff-gone.md');
      expect(handoffs.sweepLegacy(live: const {}), 2);
      expect(legacy.existsSync(), isFalse);
    });

    test('a live session keeps its own until a later start', () {
      final kept = old('prompt-live.md');
      old('handoff-gone.md');
      expect(handoffs.sweepLegacy(live: const {'live'}), 1);
      expect(kept.existsSync(), isTrue);
    });
  });

  test('a pointer line is recognised, as written now and before', () {
    expect(
      isPromptFilePointer(promptFilePointer('/t/x.md', isPacket: false)),
      isTrue,
    );
    expect(
      isPromptFilePointer(promptFilePointer('/t/x.md', isPacket: true)),
      isTrue,
    );
    expect(
      isPromptFilePointer(
        'Your handoff brief for this session is the file C:\\d\\handoff\\'
        'handoff-s1.md. Read all of it before doing anything else.',
      ),
      isTrue,
    );
    expect(isPromptFilePointer('Fix the cart total.'), isFalse);
  });
}
