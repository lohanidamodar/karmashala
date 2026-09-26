import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_export.dart';
import 'package:karmashala_session/events.dart';
import 'package:riverpod/riverpod.dart';

import '../../support/fakes.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

/// An export is a formatter over what Karmashala already recorded. Its one
/// job beyond that is to be honest about the parts it could not read — an
/// archive that quietly omits the conversation is worse than no archive.
class _Locator implements SessionTranscriptLocator {
  _Locator(this.path);
  final String? path;

  @override
  Future<String?> locate({
    required String agentId,
    required String externalSessionId,
  }) async => path;

  @override
  Future<Map<String, String>> index() async => const {};
}

void main() {
  late Directory temp;
  ProviderContainer? container;
  late FakeDataServer server;

  Future<ProviderContainer> build({
    String? transcriptPath,
    bool seedRow = true,
  }) async {
    server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    if (seedRow) {
      server.projectRows.insert(project());
      server.repositoryRows.insert(repository());
      server.installationRows.insert(agentInstallation());
      server.sessionRows.insert(
        session(
          title: 'Port the importer',
        ).copyWith(externalSessionId: 'conv-1'),
      );
    }
    return ProviderContainer(
      overrides: [
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        sessionTranscriptLocatorProvider.overrideWithValue(
          _Locator(transcriptPath),
        ),
      ],
    );
  }

  setUp(() => temp = Directory.systemTemp.createTempSync('export-test'));
  tearDown(() {
    container?.dispose();
    container = null;
    temp.deleteSync(recursive: true);
  });

  /// A Claude Code JSONL transcript with [turns] exchanges.
  String writeTranscript(int turns) {
    final file = File('${temp.path}/conv-1.jsonl');
    file.writeAsStringSync(
      [
        for (var i = 0; i < turns; i++) ...[
          jsonEncode({
            'type': 'user',
            'message': {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': 'ask $i'},
              ],
            },
          }),
          jsonEncode({
            'type': 'assistant',
            'message': {
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': 'answer $i'},
              ],
            },
          }),
        ],
      ].join('\n'),
    );
    return file.path;
  }

  String entry(SessionExport export, String name) =>
      utf8.decode(export.entries.firstWhere((e) => e.name == name).bytes);

  Future<SessionExport> exportIt() =>
      container!.read(sessionExporterProvider).build('s1');

  test('names the archive after the session, and after its id', () async {
    container = await build();
    final export = await exportIt();
    expect(export.fileName, 'port-the-importer-s1.zip');
  });

  test('carries a README, the data and the conversation', () async {
    container = await build(transcriptPath: writeTranscript(2));
    final export = await exportIt();
    expect(
      export.entries.map((e) => e.name),
      containsAll(['README.md', 'session.json', 'transcript.md']),
    );
    expect(export.turns, 4);
    expect(entry(export, 'transcript.md'), contains('ask 0'));
    expect(entry(export, 'transcript.md'), contains('answer 1'));
    // And the bytes really are an archive.
    expect(export.bytes.sublist(0, 2), [0x50, 0x4b]);
  });

  test('the JSON names the session by the id the app uses', () async {
    container = await build(transcriptPath: writeTranscript(1));
    final data =
        jsonDecode(entry(await exportIt(), 'session.json'))
            as Map<String, Object?>;
    final row = data['session']! as Map<String, Object?>;
    expect(row['id'], 's1');
    expect(row['conversationId'], 'conv-1');
    expect(row['agentName'], 'Claude Code');
    expect((data['checkout']! as Map<String, Object?>)['name'], 'app');
  });

  test(
    'a transcript nobody could find is said, not silently dropped',
    () async {
      container = await build();
      final export = await exportIt();
      expect(export.transcriptRefusal, contains('was not found'));
      expect(entry(export, 'transcript.md'), contains('no transcript'));
      // The one sentence that keeps the archive from lying by omission.
      expect(
        entry(export, 'transcript.md'),
        contains('not the same as nothing having been said'),
      );
      expect(entry(export, 'README.md'), contains('**absent**'));
    },
  );

  test(
    'a session that never opened a conversation is empty, not lost',
    () async {
      container = await build(seedRow: false);
      server.projectRows.insert(project());
      server.repositoryRows.insert(repository());
      server.installationRows.insert(agentInstallation());
      server.sessionRows.insert(session(title: 'Fresh'));

      final export = await container!.read(sessionExporterProvider).build('s1');
      expect(export.transcriptRefusal, isNull);
      expect(entry(export, 'transcript.md'), contains('Nothing was said'));
    },
  );

  test('the README says what is not in the archive', () async {
    container = await build(transcriptPath: writeTranscript(1));
    final readme = entry(await exportIt(), 'README.md');
    expect(readme, contains('What is **not** in here'));
    // The three things a reader would otherwise assume they had.
    expect(readme, contains('**The files.**'));
    expect(readme, contains('**Tool calls.**'));
    expect(readme, contains('record of what was recorded'));
  });

  test(
    'decisions travel as their own readable file, with attribution',
    () async {
      container = await build(transcriptPath: writeTranscript(1));
      server.decisionRows.append(
        DecisionRecord(
          sessionId: 's1',
          kind: DecisionKind.approachRejected,
          summary: 'The isolate pool deadlocked on Windows.',
          decidedBy: 'Claude Code',
          origin: DecisionOrigin.verificationRun,
          originId: 'v-1',
          recordedAt: testTime,
        ),
      );
      final export = await exportIt();
      final decisions = entry(export, 'decisions.md');
      expect(decisions, contains('isolate pool deadlocked'));
      expect(decisions, contains('Claude Code'));
      expect(decisions, contains('verificationRun'));
      expect(entry(export, 'session.json'), contains('"originId": "v-1"'));
    },
  );

  test('no decisions means no decisions file, not an empty one', () async {
    container = await build(transcriptPath: writeTranscript(1));
    final export = await exportIt();
    expect(export.entries.map((e) => e.name), isNot(contains('decisions.md')));
    expect(entry(export, 'README.md'), contains('nothing was recorded'));
  });

  test('a session that is gone is refused rather than half-exported', () async {
    container = await build();
    expect(
      () => container!.read(sessionExporterProvider).build('missing'),
      throwsA(isA<StateError>()),
    );
  });

  group('exportFileName', () {
    test('kebabs a title and keeps it openable on any filesystem', () {
      expect(
        exportFileName('Fix the: parser!', 'abc12345'),
        'fix-the-parser-abc12345.zip',
      );
      expect(exportFileName('  ', 'abc12345'), 'session-abc12345.zip');
    });

    test('shortens a very long title rather than refusing it', () {
      final name = exportFileName('x' * 200, 'abcdefghijkl');
      expect(name.length, lessThan(80));
      expect(name, endsWith('-abcdefgh.zip'));
    });
  });
}
