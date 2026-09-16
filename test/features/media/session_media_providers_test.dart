import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/media/application/session_media_providers.dart';
import 'package:karmashala/src/features/media/domain/session_media_item.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';

import '../../support/fixtures.dart';
import 'session_media_fixture.dart';
import '../../support/temp_directory.dart';

/// The panel end to end: a session row, the record it points at, and the list
/// the panel draws from.
///
/// Driven through an **imported** session because that is the one kind that
/// names its own transcript file — a live session's is found by scanning the
/// CLI stores, which is `SessionTranscriptLocator`'s job and is tested where it
/// lives. Everything downstream of "here is the file" is the same for both.
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
    dir = Directory.systemTemp.createTempSync('media_providers');
  });
  tearDown(() {
    db.close();
    removeTempDirectory(dir);
  });

  ImportedSession imported({
    String id = 'i1',
    required String filePath,
    String environmentId = 'windows',
  }) => ImportedSession(
    id: id,
    repositoryId: 'r1',
    cli: AgentIds.claudeCode,
    externalId: 'ext-1',
    environmentId: environmentId,
    filePath: filePath,
    storeHome: dir.path,
    isSubagent: false,
    preview: 'an earlier conversation',
    createdAt: testTime,
  );

  ProviderContainer containerFor() {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        // `path_provider` is a platform channel; the cache goes somewhere real
        // instead, which is also what makes the extracted files assertable.
        sessionMediaCacheRootProvider.overrideWith(
          (ref) async => Directory('${dir.path}/cache')..createSync(),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('a pasted picture reaches the panel as a file it can draw', () async {
    // The owner's case, all the way through: they pasted a picture into the
    // terminal, and nothing in the app ever showed it.
    final transcript = writeTranscript(dir, 'a.jsonl', [
      textLine(at: '2026-09-01T10:00:00.000Z', role: 'user', text: 'hello'),
      pastedImageLine(at: '2026-09-01T10:01:00.000Z', text: 'look at this'),
    ]);
    ImportedSessionDao(db).insertIfAbsent(imported(filePath: transcript.path));
    final container = containerFor();

    final subscription = container.listen(
      sessionMediaProvider('i1'),
      (_, _) {},
    );
    addTearDown(subscription.close);
    final items = await container.read(sessionMediaProvider('i1').future);

    expect(items, hasLength(1));
    expect(items.single.origin, SessionMediaOrigin.pasted);
    expect(File(items.single.path!).existsSync(), isTrue);
    expect(items.single.fromAgentEnvironment, isFalse);
  });

  test('a session with no record at all is an empty panel, not an error', () async {
    ImportedSessionDao(
      db,
    ).insertIfAbsent(imported(filePath: '${dir.path}/never-written.jsonl'));
    final container = containerFor();

    final subscription = container.listen(
      sessionMediaProvider('i1'),
      (_, _) {},
    );
    addTearDown(subscription.close);

    expect(await container.read(sessionMediaProvider('i1').future), isEmpty);
  });

  test(
    'an append is noticed when the modification time does not move',
    () async {
      final transcript = writeTranscript(dir, 'coarse-clock.jsonl', [
        textLine(at: '2026-09-01T10:00:00.000Z', role: 'user', text: 'hello'),
      ]);
      final originalModified = transcript.lastModifiedSync();
      ImportedSessionDao(db)
          .insertIfAbsent(imported(filePath: transcript.path));
      final container = containerFor();
      final nextItems = Completer<List<SessionMediaItem>>();
      var sawInitial = false;
      final subscription = container.listen(sessionMediaProvider('i1'), (
        _,
        value,
      ) {
        final items = value.asData?.value;
        if (items == null) return;
        if (!sawInitial) {
          sawInitial = true;
        } else if (items.isNotEmpty && !nextItems.isCompleted) {
          nextItems.complete(items);
        }
      });
      addTearDown(subscription.close);

      expect(await container.read(sessionMediaProvider('i1').future), isEmpty);
      appendTranscript(transcript, [
        pastedImageLine(at: '2026-09-01T10:01:00.000Z'),
      ]);
      transcript.setLastModifiedSync(originalModified);

      final items = await nextItems.future.timeout(
        kSessionMediaPollInterval + const Duration(seconds: 2),
      );
      expect(items, hasLength(1));
      expect(items.single.origin, SessionMediaOrigin.pasted);
    },
  );

  test('a session nobody has heard of yields nothing', () async {
    final container = containerFor();
    final subscription = container.listen(
      sessionMediaProvider('gone'),
      (_, _) {},
    );
    addTearDown(subscription.close);

    expect(await container.read(sessionMediaProvider('gone').future), isEmpty);
  });

  group('translating a path the agent wrote', () {
    test('a session running in WSL gets a Windows path back', () {
      // `Image.file` runs on the Windows host, so `/mnt/c/…/shot.png` has to
      // become `C:\…\shot.png` first — the same explicit step every other
      // feature makes through `EditorActions.windowsPathFor`.
      ImportedSessionDao(db).insertIfAbsent(
        imported(filePath: '${dir.path}/a.jsonl', environmentId: 'wsl:Ubuntu'),
      );
      final container = containerFor();

      final resolve = container.read(sessionMediaHostPathProvider('i1'));

      expect(resolve, isNotNull);
      expect(resolve!('/mnt/c/work/shot.png'), r'C:\work\shot.png');
    });

    test('a session already on the host is handed its path unchanged', () {
      ImportedSessionDao(
        db,
      ).insertIfAbsent(imported(filePath: '${dir.path}/a.jsonl'));
      final container = containerFor();

      final resolve = container.read(sessionMediaHostPathProvider('i1'));

      expect(resolve!(r'C:\work\shot.png'), r'C:\work\shot.png');
    });

    test('a native session takes its environment from its installation', () {
      AgentInstallationDao(
        db,
      ).insert(agentInstallation(environmentId: 'wsl:Ubuntu'));
      SessionDao(db).insert(session());
      final container = containerFor();

      final source = container.read(sessionMediaSourceProvider('s1'));

      expect(source, isNotNull);
      expect(source!.cli, AgentIds.claudeCode);
      expect(source.environmentId, 'wsl:Ubuntu');
      expect(
        source.filePath,
        isNull,
        reason: 'a live session\'s record has to be located, not assumed',
      );
    });
  });
}
