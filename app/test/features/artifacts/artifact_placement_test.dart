import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/artifacts/domain/artifact_placement.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 6, 9);
  DateTime at(int s) => t0.add(Duration(seconds: s));

  Artifact artifact(String id, int shownAt) => Artifact(
    id: id,
    sessionId: 's1',
    title: id,
    kind: ArtifactKind.html,
    mode: ArtifactMode.inline,
    origin: ArtifactOrigin.tool,
    fileName: '$id.html',
    revision: 1,
    size: 1,
    mimeType: 'text/html',
    createdAt: at(shownAt),
    updatedAt: at(shownAt),
  );

  ChatMessage msg(String role, int s) =>
      ChatMessage(role: role, text: role, at: at(s));

  test('a card sits on the agent\'s reply after the tool that made it', () {
    final messages = [
      msg('user', 0),
      msg('tool', 5),
      msg('agent', 10),
      msg('user', 20),
      msg('agent', 25),
    ];
    final placed = placeArtifacts(messages, [artifact('a', 6)]);
    expect(placed.byOrdinal[2]!.single.id, 'a');
    expect(placed.unplaced, isEmpty);
  });

  test('with no reply yet in that turn, the turn\'s last agent row', () {
    final messages = [msg('user', 0), msg('agent', 3), msg('tool', 5)];
    final placed = placeArtifacts(messages, [artifact('a', 6)]);
    expect(placed.byOrdinal[1]!.single.id, 'a');
  });

  test('a reply in a later turn is not where it goes', () {
    final messages = [
      msg('user', 0),
      msg('agent', 3),
      msg('user', 7),
      msg('agent', 9),
    ];
    final placed = placeArtifacts(messages, [artifact('a', 5)]);
    expect(placed.byOrdinal[1]!.single.id, 'a');
  });

  test('two artifacts of one turn stay in the order shown', () {
    final messages = [msg('user', 0), msg('agent', 10)];
    final placed = placeArtifacts(messages, [
      artifact('a', 2),
      artifact('b', 3),
    ]);
    expect(placed.byOrdinal[1]!.map((a) => a.id), ['a', 'b']);
  });

  test('no message to hang it on, or none timed: it is unplaced', () {
    final untimed = [
      const ChatMessage(role: 'user', text: 'u'),
      const ChatMessage(role: 'agent', text: 'a'),
    ];
    expect(placeArtifacts(untimed, [artifact('a', 1)]).unplaced, hasLength(1));
    expect(placeArtifacts(const [], [artifact('a', 1)]).unplaced, hasLength(1));
  });

  test('an artifact older than the window held is unplaced, not misfiled', () {
    final messages = [msg('user', 100), msg('agent', 110)];
    final placed = placeArtifacts(messages, [artifact('a', 5)]);
    expect(placed.unplaced.single.id, 'a');
  });
}
