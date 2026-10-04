import 'dart:convert';

import 'package:agent_cli/stream.dart' show FileEditKind, kMaxToolEditChars;
import 'package:karmashala_acp/karmashala_acp.dart';
import 'package:karmashala_host/src/acp/acp_conversation_writer.dart';
import 'package:karmashala_host/src/sessions/session_message_transcripts.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// An ACP edit's diff survives the trip from `session/update` to the chat's
/// tool row: stored bounded by the writer, projected onto `ToolActivity`.
void main() {
  final at = DateTime.utc(2026, 10, 4, 9);
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

  SessionMessage toolRow() =>
      dao.listAfter('s1').singleWhere((r) => r.toolJson != null);

  test('an edit keeps its kind, its input and its diff', () {
    writer.update(
      const ToolCallUpdate(
        toolCallId: 'c1',
        isNew: true,
        title: 'Edit lib/a.dart',
        kind: ToolKind.edit,
        status: ToolCallStatus.pending,
        rawInput: {
          'file_path': '/src/lib/a.dart',
          'old_string': 'a',
          'new_string': 'b',
        },
      ),
    );
    writer.update(
      const ToolCallUpdate(
        toolCallId: 'c1',
        status: ToolCallStatus.completed,
        content: [
          ToolCallDiff(
            path: '/src/lib/a.dart',
            oldText: 'one\ntwo\n',
            newText: 'one\nthree\n',
          ),
          ToolCallDiff(path: '/src/lib/new.dart', newText: 'fresh'),
        ],
      ),
    );

    final tool = SessionMessageTranscriptSource.project(toolRow()).tool!;
    expect(tool.kind, 'edit');
    // No `locations`: the input names the file.
    expect(tool.subject, '/src/lib/a.dart');
    expect(tool.edits.map((e) => (e.path, e.kind)), [
      ('/src/lib/a.dart', FileEditKind.modified),
      ('/src/lib/new.dart', FileEditKind.created),
    ]);
    expect(tool.edits.first.oldText, 'one\ntwo\n');
    expect(tool.edits.first.newText, 'one\nthree\n');
    expect(tool.editsTruncated, isFalse);
  });

  test('a call still running already shows the diff it carries', () {
    writer.update(
      const ToolCallUpdate(
        toolCallId: 'c2',
        isNew: true,
        kind: ToolKind.edit,
        status: ToolCallStatus.inProgress,
        content: [ToolCallDiff(path: 'x', oldText: 'a', newText: 'b')],
      ),
    );
    final message = SessionMessageTranscriptSource.project(toolRow());
    expect(message.pendingToolUseId, 'c2');
    expect(message.tool!.edits.single.newText, 'b');
  });

  test('a whole-file diff is stored as its changed region', () {
    final lines = [for (var i = 0; i < 20000; i++) 'line $i'];
    final before = lines.join('\n');
    lines[500] = 'changed';
    writer.update(
      ToolCallUpdate(
        toolCallId: 'c3',
        isNew: true,
        kind: ToolKind.edit,
        status: ToolCallStatus.completed,
        content: [
          ToolCallDiff(path: 'big', oldText: before, newText: lines.join('\n')),
        ],
      ),
    );

    final row = toolRow();
    expect(row.toolJson!.length, lessThan(4096));
    final tool = SessionMessageTranscriptSource.project(row).tool!;
    expect(tool.edits.single.newText, contains('changed'));
    expect(tool.editsTruncated, isFalse);
    // The writer's own view of the call, which permissions answer from, is
    // untouched.
    final diff = writer.toolCall('c3')!.content!.single as ToolCallDiff;
    expect(diff.oldText, before);
  });

  test('a diff past the budget is stored cut, and says so', () {
    final huge = List.filled(40000, 'generated line').join('\n');
    writer.update(
      ToolCallUpdate(
        toolCallId: 'c4',
        isNew: true,
        kind: ToolKind.edit,
        status: ToolCallStatus.completed,
        rawInput: {'file_path': 'gen.txt', 'content': huge},
        content: [ToolCallDiff(path: 'gen.txt', newText: huge)],
      ),
    );

    final row = toolRow();
    expect(row.toolJson!.length, lessThan(kMaxToolEditChars + 16 * 1024));
    final tool = SessionMessageTranscriptSource.project(row).tool!;
    expect(tool.editsTruncated, isTrue);
    expect(tool.edits.single.kind, FileEditKind.created);
    expect(tool.subject, 'gen.txt');
    expect(jsonDecode(row.toolJson!), containsPair('kind', 'edit'));
  });
}
