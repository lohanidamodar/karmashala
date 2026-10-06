import 'dart:convert';

import 'package:karmashala_acp/karmashala_acp.dart';
import 'package:karmashala_host/src/acp/acp_conversation_writer.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// Each plan an ACP agent publishes is kept: a turn that changes its plan
/// three times leaves three rows, the newest the plan as it stands.
void main() {
  final at = DateTime.utc(2026, 10, 6, 9);
  late AppDatabase db;
  late SessionMessageDao dao;
  late AcpConversationWriter writer;
  var ids = 0;

  setUp(() {
    db = AppDatabase.memory();
    db.execute('PRAGMA foreign_keys = OFF;');
    dao = SessionMessageDao(db, now: () => at);
    writer = AcpConversationWriter(
      sessionId: 's1',
      messages: dao,
      newId: () => 'row${ids++}',
      onChanged: () {},
      now: () => at,
    );
  });

  tearDown(() {
    writer.close();
    db.close();
  });

  PlanUpdate plan(List<(String, PlanEntryStatus)> entries) => PlanUpdate([
    for (final (content, status) in entries)
      PlanEntry(content: content, status: status),
  ]);

  List<List<String>> planRows() => [
    for (final row in dao.listAfter('s1'))
      if (row.planJson case final String json)
        [
          for (final entry in (jsonDecode(json) as Map)['entries'] as List)
            '${(entry as Map)['content']}:${entry['status']}',
        ],
  ];

  test('every change within a turn is its own row', () {
    writer.update(plan([('A', PlanEntryStatus.pending)]));
    writer.update(
      plan([('A', PlanEntryStatus.pending), ('B', PlanEntryStatus.pending)]),
    );
    writer.update(
      plan([('A', PlanEntryStatus.inProgress), ('B', PlanEntryStatus.pending)]),
    );

    expect(planRows(), [
      ['A:pending'],
      ['A:pending', 'B:pending'],
      ['A:in_progress', 'B:pending'],
    ]);
  });

  test('a plan sent again unchanged adds nothing', () {
    writer.update(plan([('A', PlanEntryStatus.pending)]));
    writer.update(plan([('A', PlanEntryStatus.pending)]));
    writer.turnEnded();
    writer.update(plan([('A', PlanEntryStatus.pending)]));

    expect(planRows(), [
      ['A:pending'],
    ]);
  });
}
