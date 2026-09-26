import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/conversation_index_backfill.dart';
import 'package:karmashala/src/features/cli_detection/application/conversation_indexer.dart';
import 'package:karmashala/src/features/cli_detection/data/conversation_index_dao.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fixtures.dart';

class _FixedClock implements Clock {
  const _FixedClock();

  @override
  DateTime nowUtc() => DateTime.utc(2026, 9, 8, 12);
}

String _line(Map<String, Object?> json) => '${jsonEncode(json)}\n';

void main() {
  late Directory dir;
  late AppDatabase db;
  late ConversationIndexDao dao;
  late ConversationIndexer indexer;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('conversation_backfill_');
    db = AppDatabase.memory();
    dao = ConversationIndexDao(db);
    indexer = ConversationIndexer(dao: dao, clock: const _FixedClock());
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(
      db,
    ).insert(agentInstallation(agentId: AgentIds.claudeCode));
  });
  tearDown(() {
    db.close();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps a handle on a file a failing test left open.
    }
  });

  String transcript(String name, String said) {
    final path = '${dir.path}/$name';
    File(path).writeAsStringSync(
      _line({
        'type': 'user',
        'message': {'role': 'user', 'content': said},
      }),
    );
    return path;
  }

  void importedRow(String externalId, String filePath) {
    ImportedSessionDao(db).insertIfAbsent(
      ImportedSession(
        id: 'i-$externalId',
        repositoryId: 'r1',
        cli: AgentIds.claudeCode,
        externalId: externalId,
        environmentId: 'windows',
        filePath: filePath,
        storeHome: dir.path,
        isSubagent: false,
        preview: 'preview',
        createdAt: testTime,
      ),
    );
  }

  void nativeRow(String id, String externalId) {
    SessionDao(db).insert(
      Session(
        id: id,
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Named by the user',
        useWorktree: false,
        workingDirectory: const EnvironmentPath(
          environmentId: 'windows',
          path: r'C:\src\demo\app',
        ),
        status: SessionStatus.running,
        createdAt: testTime,
        externalSessionId: externalId,
      ),
    );
  }

  ConversationIndexBackfill backfill({
    Future<Map<String, String>> Function()? locate,
    List<String>? walkLog,
  }) => ConversationIndexBackfill(
    db: db,
    dao: dao,
    indexer: indexer,
    clock: const _FixedClock(),
    locateTranscripts:
        locate ??
        () async {
          walkLog?.add('walked');
          return const {};
        },
  );

  test('imported history is indexed from the path on its row', () async {
    importedRow('c1', transcript('c1.jsonl', 'the caching decision'));
    final walks = <String>[];

    expect(await backfill(walkLog: walks).runOnce(), 1);

    expect(dao.search('caching'), hasLength(1));
    // Free: every path was already on a row, so nothing walked a store.
    expect(walks, isEmpty);
  });

  test('a live conversation with no recorded path costs one walk', () async {
    nativeRow('s1', 'c1');
    final path = transcript('c1.jsonl', 'the worktree decision');
    var walks = 0;

    final job = backfill(
      locate: () async {
        walks++;
        return {'${AgentIds.claudeCode}/c1': path};
      },
    );
    expect(await job.runOnce(), 1);

    expect(walks, 1);
    expect(job.walks, 1);
    expect(dao.search('worktree'), hasLength(1));
  });

  test('a superseded record still supplies the only path there is', () async {
    // History imported first, then resumed — so a native row now represents
    // the conversation and `ImportedSessionDao` hides the record from every
    // list. It is still the only place that transcript's path is written down,
    // which is why the backfill reads the table unfiltered.
    importedRow('c1', transcript('c1.jsonl', 'the superseded decision'));
    nativeRow('s1', 'c1');
    final walks = <String>[];

    await backfill(walkLog: walks).runOnce();

    expect(dao.search('superseded'), hasLength(1));
    expect(walks, isEmpty, reason: 'nothing was left without a path');
  });

  test('it is a one-off: the second run does nothing at all', () async {
    importedRow('c1', transcript('c1.jsonl', 'said once'));
    await backfill().runOnce();

    var walks = 0;
    final again = backfill(
      locate: () async {
        walks++;
        return const {};
      },
    );
    expect(again.isDone, isTrue);
    expect(await again.runOnce(), 0);

    expect(walks, 0);
    expect(indexer.parses, 1, reason: 'one parse across both runs');
    expect(
      db.readMetadata(MetadataKeys.conversationIndexBackfilledAt),
      isNotNull,
    );
  });

  test('a transcript that is gone does not stop the ones present', () async {
    importedRow('gone', '${dir.path}/never-written.jsonl');
    importedRow('here', transcript('here.jsonl', 'the surviving decision'));

    await backfill().runOnce();

    expect(dao.search('surviving'), hasLength(1));
    // Recorded as looked-at with nothing found, rather than left unknown.
    expect(dao.stateFor('gone')!.turns, 0);
    expect(dao.stateFor('gone')!.modifiedAt, isNull);
  });

  test('a store walk that throws leaves the recorded paths indexed', () async {
    nativeRow('s1', 'nowhere');
    importedRow('here', transcript('here.jsonl', 'the recorded decision'));

    await backfill(
      locate: () => Future.error(const FileSystemException('x')),
    ).runOnce();

    expect(dao.search('recorded'), hasLength(1));
  });

  test('an empty workspace is done without walking anything', () async {
    final walks = <String>[];
    expect(await backfill(walkLog: walks).runOnce(), 0);
    expect(walks, isEmpty);
    expect(indexer.parses, 0);
  });
}
