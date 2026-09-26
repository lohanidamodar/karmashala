import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/media/application/session_media_providers.dart';
import 'package:karmashala/src/features/media/domain/session_media_item.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';

import '../../support/fixtures.dart';
import 'session_media_fixture.dart';
import '../../support/temp_directory.dart';

/// Turning a `[Image #6]` printed in a pane into the picture it names — or into
/// a sentence saying why it cannot.
///
/// The owner's request: *"i should be able to ctrl click on the image
/// `[Image #6]` and preview the image in dialog"*. The number is the CLI's own
/// `imagePasteIds` value, not an ordinal — `session_image_reference.dart`
/// records the transcripts that establish that — so the lookup is a search for
/// an id and never arithmetic on a position.
///
/// Driven through an **imported** session for the same reason
/// `session_media_providers_test.dart` is: it is the one kind that names its
/// own transcript file. Everything downstream of "here is the file" is shared.
void main() {
  late AppDatabase db;
  late Directory dir;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv())
      ..upsert(wslEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    dir = Directory.systemTemp.createTempSync('image_lookup');
  });
  tearDown(() {
    db.close();
    removeTempDirectory(dir);
  });

  void register(String filePath) => ImportedSessionDao(db).insertIfAbsent(
    ImportedSession(
      id: 'i1',
      repositoryId: 'r1',
      cli: AgentIds.claudeCode,
      externalId: 'ext-1',
      environmentId: 'windows',
      filePath: filePath,
      storeHome: dir.path,
      isSubagent: false,
      preview: 'an earlier conversation',
      createdAt: testTime,
    ),
  );

  ProviderContainer containerFor() {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sessionMediaCacheRootProvider.overrideWith(
          (ref) async => Directory('${dir.path}/cache')..createSync(),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<SessionImageLookup> look(int pasteId, {String session = 'i1'}) =>
      containerFor().read(sessionImageLookupProvider)(session, pasteId);

  test('a reference resolves to the picture the CLI numbered', () async {
    // Two `Read` results before the paste, so the paste is the scan's third
    // item while the CLI called it #6. Position would find the wrong one.
    final transcript = writeTranscript(dir, 'a.jsonl', [
      toolUseLine(
        at: '2026-09-01T10:00:00.000Z',
        id: 't1',
        name: 'Read',
        input: {'file_path': '/mnt/c/work/a.png'},
      ),
      toolUseLine(
        at: '2026-09-01T10:00:01.000Z',
        id: 't2',
        name: 'Read',
        input: {'file_path': '/mnt/c/work/b.png'},
      ),
      pastedImageLine(
        at: '2026-09-01T10:00:02.000Z',
        text: '[Image #6] this the doorway blocked',
        pasteIds: [6],
      ),
    ]);
    register(transcript.path);

    final found = await look(6);

    expect(found, isA<SessionImageFound>());
    final item = (found as SessionImageFound).item;
    expect(item.pasteId, 6);
    expect(item.origin, SessionMediaOrigin.pasted);
    expect(File(item.path!).existsSync(), isTrue, reason: 'drawable on disk');
  });

  test('the newest picture wins when the CLI restarted its counter', () async {
    // Real shape, from `…/appwrite-ai-workdir/7977d17c-….jsonl`, which holds
    // two different pictures both recorded as `imagePasteIds:[6]`. The number
    // on screen belongs to the CLI process running *now*, so the later one is
    // the only defensible answer.
    final transcript = writeTranscript(dir, 'a.jsonl', [
      pastedImageLine(
        at: '2026-09-01T10:00:00.000Z',
        text: '[Image #6] the first one',
        pasteIds: [6],
      ),
      pastedImageLine(
        at: '2026-09-01T11:00:00.000Z',
        text: '[Image #6] after a restart',
        pasteIds: [6],
      ),
    ]);
    register(transcript.path);

    final found = await look(6);

    expect((found as SessionImageFound).item.sequence, 1);
    // And it is carried out that this was a choice, not a certainty: the pane
    // cannot tell an old scrollback line from a fresh one, so the dialog has
    // to be able to say the number was used more than once.
    expect(found.matches, 2);
  });

  test('a number used once says so, so the dialog stays quiet', () async {
    final transcript = writeTranscript(dir, 'a.jsonl', [
      pastedImageLine(
        at: '2026-09-01T10:00:00.000Z',
        text: '[Image #6] the only one',
        pasteIds: [6],
      ),
    ]);
    register(transcript.path);

    final found = await look(6);

    expect((found as SessionImageFound).matches, 1);
  });

  test('a number the session has no picture for is refused in words', () async {
    final transcript = writeTranscript(dir, 'a.jsonl', [
      pastedImageLine(
        at: '2026-09-01T10:00:00.000Z',
        text: '[Image #1] here',
        pasteIds: [1],
      ),
    ]);
    register(transcript.path);

    final answer = await look(6);

    // Not "nothing happened", and emphatically not the picture that *is*
    // there: a sentence naming what was asked for.
    expect(answer, isA<SessionImageUnavailable>());
    expect((answer as SessionImageUnavailable).reason, contains('[Image #6]'));
  });

  test('a session Karmashala has no record for is refused in words', () async {
    final answer = await look(6, session: 'nobody');

    expect(answer, isA<SessionImageUnavailable>());
    expect((answer as SessionImageUnavailable).reason, contains('[Image #6]'));
  });

  test('a picture the scan could not draw reports its own problem', () async {
    // A block whose bytes the transcript never carried. The scan lists it —
    // it is still something the session had — but there is nothing on disk to
    // open, so the reason handed back has to be the store's own words rather
    // than a viewer opening onto an empty frame.
    final transcript = writeTranscript(dir, 'a.jsonl', [
      jsonEncode({
        'type': 'user',
        'timestamp': '2026-09-01T10:00:00.000Z',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '[Image #2] look'},
            {
              'type': 'image',
              'source': {'type': 'url', 'url': 'https://example.com/a.png'},
            },
          ],
        },
        'imagePasteIds': [2],
      }),
    ]);
    register(transcript.path);

    final answer = await look(2);

    expect(answer, isA<SessionImageUnavailable>());
    expect(
      (answer as SessionImageUnavailable).reason,
      contains('not stored in the transcript'),
    );
  });
}
