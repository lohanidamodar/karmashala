import 'package:agent_cli/stream.dart' show ToolActivity;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/artifacts/domain/visual_placement.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 8, 9);
  DateTime at(int s) => t0.add(Duration(seconds: s));

  SessionVisual visual(String id, int drawnAt) => SessionVisual(
    sessionId: 's1',
    id: id,
    kind: 'progress',
    data: const {'value': 1.0},
    revision: 1,
    createdAt: at(drawnAt),
    updatedAt: at(drawnAt),
  );

  ChatMessage msg(String role, int? s) =>
      ChatMessage(role: role, text: role, at: s == null ? null : at(s));

  ChatMessage call(
    String id,
    int? s, {
    String name = 'mcp__karmashala__visualize',
  }) => ChatMessage(
    role: 'tool',
    text: '',
    at: s == null ? null : at(s),
    tool: ToolActivity(name: name, output: '{"id": "$id", "revision": 1}'),
  );

  test('the call\'s own row places it, even with no times at all', () {
    // A terminal session whose record carries no times: the transcript
    // position is the visualize row.
    final messages = [
      msg('user', null),
      msg('agent', null),
      call('build', null),
      msg('tool', null),
      msg('user', null),
      msg('agent', null),
    ];
    final placed = placeVisuals(messages, [visual('build', 999)]);
    expect(placed.byOrdinal[1], ['build']);
    expect(placed.trailing, isEmpty);
  });

  test('a call answering another id is not its row', () {
    final messages = [msg('user', 0), msg('agent', 1), call('other', 2)];
    final placed = placeVisuals(messages, [visual('build', 50)]);
    // By time instead: after the last message, in the same turn.
    expect(placed.byOrdinal[1], ['build']);
  });

  test('by time, under the agent words before it in its turn', () {
    final messages = [
      msg('user', 0),
      msg('agent', 2),
      msg('tool', 4),
      msg('user', 10),
      msg('agent', 12),
    ];
    expect(placeVisuals(messages, [visual('v', 5)]).byOrdinal[1], ['v']);
  });

  test('no words before it in its turn: the first after', () {
    final messages = [msg('user', 0), msg('tool', 2), msg('agent', 6)];
    expect(placeVisuals(messages, [visual('v', 3)]).byOrdinal[2], ['v']);
  });

  test('a turn with no words yet draws it at the end', () {
    final messages = [msg('agent', 0), msg('user', 5), call('p', 6)];
    final placed = placeVisuals(messages, [visual('p', 6)]);
    expect(placed.byOrdinal, isEmpty);
    expect(placed.trailing, ['p']);
  });

  test('older than every message held belongs to an earlier page', () {
    final messages = [msg('user', 100), msg('agent', 101)];
    final placed = placeVisuals(messages, [visual('old', 5)]);
    expect(placed.earlier, ['old']);
    expect(placed.byOrdinal, isEmpty);
  });

  test('the key changes when a visual moves, not when it updates', () {
    final messages = [msg('user', 0), msg('agent', 1)];
    final a = placeVisuals(messages, [visual('v', 2)]);
    final b = placeVisuals(messages, [visual('v', 2)]);
    expect(a.key, b.key);
    final c = placeVisuals([...messages, msg('user', 3)], [visual('v', 4)]);
    expect(c.key, isNot(a.key));
  });
}
