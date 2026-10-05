import 'dart:io';

import 'package:agent_cli/read.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:test/test.dart';

/// A phone is told every background run the session is waiting on, from the
/// same reading as its turns, and again from the memo while the file holds
/// still — the turn that launched them being over or not.
void main() {
  final issued = DateTime.utc(2026, 10, 5, 6);
  late Directory dir;
  late File record;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('records_bg');
    record = File('${dir.path}/s1.jsonl')..writeAsStringSync('{}');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  TranscriptMessage launch(String id, BackgroundRunState state) =>
      TranscriptMessage(
        role: 'tool',
        text: 'Agent($id)',
        at: issued,
        background: BackgroundRun(
          id: id,
          kind: BackgroundRunKind.agent,
          state: state,
          description: 'job $id',
        ),
      );

  test('two background agents reach the phone, and stay while the file '
      'holds still', () async {
    final records = AgentRecords(
      read: (path, agentId) async => [
        launch('a1', BackgroundRunState.running),
        launch('a2', BackgroundRunState.running),
        const TranscriptMessage(role: 'agent', text: 'Waiting on both.'),
      ],
    );

    final reading = await records.read('s1', (
      path: record.path,
      agentId: 'claudeCode',
    ));

    expect(reading!.background.map((r) => r.id), ['a1', 'a2']);
    expect(reading.background.every((r) => r.agent && r.isRunning), isTrue);
    expect(reading.background.first.description, 'job a1');
    expect(reading.background.first.startedAt, issued);

    final since = await records.since('s1');
    expect(since!.background!.map((r) => r.id), ['a1', 'a2']);
  });
}
