import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/sessions/launch/handoff_delivery.dart';
import 'package:karmashala_host/src/sessions/launch/session_handoffs.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// What happens to a launch's handoff after the agent starts: an opening to
/// type waits for a ready composer, holding the queue meanwhile; a file is
/// deleted once the agent has it, or when the session ends.
void main() {
  late AppDatabase database;
  late Directory temp;
  late SessionHandoffs handoffs;
  late HandoffDelivery delivery;
  late DateTime clock;
  late Map<String, bool> held, ready, working;
  late List<(String, String)> delivered;
  late List<String> holds, releases;
  Object? refuse;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('handoff_delivery');
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    clock = DateTime.utc(2026, 10, 4, 12);
    handoffs = SessionHandoffs(
      dao: SessionHandoffDao(database),
      root: Directory(p.join(temp.path, 'root')),
      now: () => clock,
    );
    held = {};
    ready = {};
    working = {};
    delivered = [];
    holds = [];
    releases = [];
    refuse = null;
    delivery = HandoffDelivery(
      handoffs: handoffs,
      holds: (id) => held[id] ?? false,
      ready: (id) => ready[id] ?? false,
      working: (id) => working[id] ?? false,
      deliver: (id, text) async {
        final refusal = refuse;
        if (refusal != null) throw refusal;
        delivered.add((id, text));
      },
      hold: holds.add,
      release: releases.add,
      now: () => clock,
    );
  });

  tearDown(() async {
    await delivery.close();
    database.close();
    temp.deleteSync(recursive: true);
  });

  Future<void> after(Duration d) {
    clock = clock.add(d);
    return delivery.tick();
  }

  const step = Duration(seconds: 1);

  group('a typed opening', () {
    setUp(() {
      handoffs.record(
        's1',
        HandoffKind.opening,
        'one\ntwo',
        HandoffRoute.typed,
      );
      delivery.watch('s1');
    });

    test('holds the queue and waits for a ready composer', () async {
      expect(holds, ['s1']);
      held['s1'] = true;
      await after(step);
      expect(delivered, isEmpty);
      ready['s1'] = true;
      await after(step);
      // Ready must hold a moment before anything is typed.
      expect(delivered, isEmpty);
      await after(step);
      expect(delivered, [('s1', 'one\ntwo')]);
      expect(
        SessionHandoffDao(database).get('s1', HandoffKind.opening)!.consumedAt,
        clock,
      );
      expect(releases, isEmpty);
      working['s1'] = true;
      await after(step);
      expect(releases, ['s1']);
      await after(step);
      expect(delivered, hasLength(1));
    });

    test('lets the queue go when the turn is not seen to start', () async {
      held['s1'] = true;
      ready['s1'] = true;
      await after(step);
      await after(step);
      expect(delivered, hasLength(1));
      await after(HandoffDelivery.turnStartGrace + step);
      expect(releases, ['s1']);
    });

    test('a refused send is tried again at the next ready', () async {
      held['s1'] = true;
      ready['s1'] = true;
      refuse = const DataRefused(DataRefusalCode.conflict, 'prompt open');
      await after(step);
      await after(step);
      expect(delivered, isEmpty);
      expect(
        SessionHandoffDao(database).get('s1', HandoffKind.opening)!.consumedAt,
        isNull,
      );
      refuse = null;
      // Ready settles again after a refusal: a prompt was open.
      await after(step);
      await after(step);
      expect(delivered, [('s1', 'one\ntwo')]);
    });

    test('a session that ends first lets the queue go and keeps nothing on '
        'disk', () async {
      held['s1'] = true;
      await after(step);
      held['s1'] = false;
      await after(step);
      expect(releases, ['s1']);
      expect(delivered, isEmpty);
      expect(
        SessionHandoffDao(database).get('s1', HandoffKind.opening)!.consumedAt,
        clock,
      );
    });

    test('a session never seen running is given up on', () async {
      await after(HandoffDelivery.startPatience + step);
      expect(releases, ['s1']);
      expect(
        SessionHandoffDao(database).get('s1', HandoffKind.opening)!.consumedAt,
        isNull,
      );
    });
  });

  group('a file', () {
    test('an opening file goes once the first turn has ended', () async {
      final path = handoffs.writeFile('s1', HandoffKind.opening, 'brief')!;
      handoffs.record('s1', HandoffKind.opening, 'brief', HandoffRoute.file);
      delivery.watch('s1');
      expect(holds, isEmpty);
      held['s1'] = true;
      ready['s1'] = true;
      await after(step);
      expect(File(path).existsSync(), isTrue);
      ready['s1'] = false;
      working['s1'] = true;
      await after(step);
      // Still being read while the turn runs.
      expect(File(path).existsSync(), isTrue);
      working['s1'] = false;
      ready['s1'] = true;
      await after(step);
      expect(File(path).existsSync(), isFalse);
      expect(handoffs.folderOf('s1').existsSync(), isFalse);
    });

    test(
      'a system-prompt file goes as soon as the first turn starts',
      () async {
        final path = handoffs.writeFile('s1', HandoffKind.systemPrompt, 'p')!;
        handoffs.record('s1', HandoffKind.systemPrompt, 'p', HandoffRoute.file);
        delivery.watch('s1');
        held['s1'] = true;
        working['s1'] = true;
        await after(step);
        expect(File(path).existsSync(), isFalse);
      },
    );

    test('goes when the session ends', () async {
      final path = handoffs.writeFile('s1', HandoffKind.opening, 'brief')!;
      handoffs.record('s1', HandoffKind.opening, 'brief', HandoffRoute.file);
      delivery.watch('s1');
      held['s1'] = true;
      await after(step);
      held['s1'] = false;
      await after(step);
      expect(File(path).existsSync(), isFalse);
    });
  });

  test('start takes up what a stopped server left waiting', () async {
    handoffs.record('s1', HandoffKind.opening, 'hi\nthere', HandoffRoute.typed);
    handoffs.record('s2', HandoffKind.opening, 'done', HandoffRoute.argv);
    delivery.start(timer: false);
    expect(holds, ['s1']);
    held['s1'] = true;
    ready['s1'] = true;
    await after(step);
    await after(step);
    expect(delivered, [('s1', 'hi\nthere')]);
  });
}
