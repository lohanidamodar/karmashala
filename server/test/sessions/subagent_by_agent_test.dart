import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/serve/server_features.dart';
import 'package:karmashala_host/src/sessions/session_transcripts.dart';
import 'package:karmashala_session/transcript.dart' show ChatViewEvidence;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A background agent opened by its run's id: the client has no path for it,
/// and the server reads `agent-<id>.jsonl` beside the session's own record,
/// never anywhere else.
void main() {
  late Directory root;
  late SessionTranscripts transcripts;

  setUp(() {
    root = Directory.systemTemp.createTempSync('subagent_by_agent');
    final record = p.join(root.path, 's1.jsonl');
    File(record).writeAsStringSync(
      '{"type":"user","message":{"role":"user","content":"go"}}\n',
    );
    Directory(p.join(root.path, 's1', 'subagents')).createSync(recursive: true);
    File(
      p.join(root.path, 's1', 'subagents', 'agent-abc.jsonl'),
    ).writeAsStringSync(
      '{"type":"user","message":{"role":"user","content":"look into it"}}'
      '\n{"type":"assistant","message":{"content":[{"type":"text",'
      '"text":"Found it."}]}}\n',
    );
    transcripts = SessionTranscripts(
      lookUp: (_) async => (path: record, agentId: 'claudeCode', absence: null),
    );
  });
  tearDown(() async {
    await transcripts.close();
    root.deleteSync(recursive: true);
  });

  test('the server offers it', () {
    expect(kServerFeatures, contains(SessionTranscriptSubagent.byAgentFeature));
  });

  test('a background agent is read by its id', () async {
    final page = await transcripts.subagent(
      const SessionTranscriptSubagent.ofAgent('s1', 'abc'),
    );
    expect(page.messages.map((m) => m.text), contains('Found it.'));
    expect(p.basename(page.path!), 'agent-abc.jsonl');
  });

  group('a session served from its messages', () {
    late SessionTranscripts acp;
    setUp(() {
      acp = SessionTranscripts(
        lookUp: (_) async => (
          path: p.join(root.path, 's1.jsonl'),
          agentId: 'claude-acp',
          absence: null,
        ),
        servesFromMessages: (_) => true,
      );
    });
    tearDown(() => acp.close());

    test("reads its subagent beside the agent's own record", () async {
      final page = await acp.subagent(
        const SessionTranscriptSubagent.ofAgent('s1', 'abc'),
      );
      expect(page.messages.map((m) => m.text), contains('Found it.'));
      expect(p.basename(page.path!), 'agent-abc.jsonl');
    });

    test('refuses an id that names no file, and any path', () async {
      for (final request in [
        const SessionTranscriptSubagent.ofAgent('s1', '../s1'),
        SessionTranscriptSubagent('s1', p.join(root.path, 's1.jsonl')),
      ]) {
        await expectLater(
          acp.subagent(request),
          throwsA(
            isA<DataRefused>().having(
              (r) => r.code,
              'code',
              DataRefusalCode.invalid,
            ),
          ),
        );
      }
    });

    test('is refused while its record cannot be found', () async {
      final lost = SessionTranscripts(
        lookUp: (_) async =>
            (path: null, agentId: null, absence: ChatViewEvidence.notLocated),
        servesFromMessages: (_) => true,
      );
      addTearDown(lost.close);
      await expectLater(
        lost.subagent(const SessionTranscriptSubagent.ofAgent('s1', 'abc')),
        throwsA(isA<DataRefused>()),
      );
    });
  });

  for (final id in ['../s1', r'..\s1', 'a/b', '', 'x.jsonl']) {
    test('an id that is not one names no file: "$id"', () async {
      await expectLater(
        transcripts.subagent(SessionTranscriptSubagent.ofAgent('s1', id)),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.code,
            'code',
            DataRefusalCode.invalid,
          ),
        ),
      );
    });
  }
}
