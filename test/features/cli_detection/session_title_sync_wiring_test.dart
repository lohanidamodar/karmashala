import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' show sqlite3;

import '../../support/fake_cli_store_locator.dart';
import '../../support/fixtures.dart';
import 'package:agent_cli/read.dart';

/// The owner's bug, end to end through the real providers.
///
/// One `agy` store on disk with `/rename`'s annotation in it, one session row
/// titled "New session", and the store slot's own call —
/// `cliStoreSyncRunnerProvider`. Every link in the chain the report broke on is
/// exercised: the store format that let detection reach the reader, the reader,
/// the mapping to a `DetectedSession`, and the sync that writes the row.
void main() {
  late Directory tmp;
  late String storeHome;
  late AppDatabase db;

  const conversation = 'df3c0708-1111-4222-8333-444455556666';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('karmashala_agy_wiring_');
    storeHome = p.join(tmp.path, '.gemini', 'antigravity-cli');
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(
      agentInstallation(agentId: AgentIds.antigravity),
    );
    SessionDao(db).insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        // What `ExplorerActions.startSession` stamps on a `+` click.
        title: 'New session',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: testTime,
        externalSessionId: conversation,
      ),
    );
  });
  tearDown(() {
    db.close();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps a handle on a database a failing test left open.
    }
  });

  void writeStore({required String title}) {
    final conversationFile = p.join(
      storeHome,
      'conversations',
      '$conversation.db',
    );
    Directory(p.dirname(conversationFile)).createSync(recursive: true);
    final store = sqlite3.open(conversationFile);
    store.execute(
      'CREATE TABLE `steps` (`idx` integer, `step_type` integer NOT NULL '
      'DEFAULT 0, `status` integer NOT NULL DEFAULT 0);',
    );
    store.close();
    File(p.join(storeHome, 'cache', 'last_conversations.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({r'C:\src\demo\app': conversation}));
    File(p.join(storeHome, 'annotations', '$conversation.pbtxt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('title:"$title"\n');
  }

  ProviderContainer container() => ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      cliStoreLocatorProvider.overrideWithValue(
        FixedLocator([
          CliStore(
            environmentId: 'windows',
            homesByAgentId: {AgentIds.antigravity: storeHome},
          ),
        ]),
      ),
    ],
  );

  test('a name typed into agy reaches the session row', () async {
    writeStore(title: 'test me now');
    final ref = container();
    addTearDown(ref.dispose);

    await ref.read(cliStoreSyncRunnerProvider)();

    expect(SessionDao(db).getById('s1')!.title, 'test me now');
  });

  test('a phantom row learns its id and its name in one slot', () async {
    // The two halves of the owner's report, together: the session was launched
    // by the app, `agy` minted an id we were never told, and the user renamed
    // in the CLI. `cliStoreSyncRunnerProvider` runs attribution before the
    // title sync precisely so both land on the same slot — the title sync can
    // only match a row that has an id.
    writeStore(title: 'test me now');
    File(
      p.join(storeHome, 'conversations', '$conversation.db'),
    ).setLastModifiedSync(testTime.add(const Duration(seconds: 5)));
    SessionDao(db).delete('s1');
    SessionDao(db).insert(
      Session(
        id: 's2',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'New session',
        useWorktree: false,
        workingDirectory: const EnvironmentPath(
          environmentId: 'windows',
          path: r'C:\src\demo\app',
        ),
        status: SessionStatus.running,
        createdAt: testTime,
      ),
    );
    final ref = container();
    addTearDown(ref.dispose);

    await ref.read(cliStoreSyncRunnerProvider)();

    final row = SessionDao(db).getById('s2')!;
    expect(row.externalSessionId, conversation);
    expect(row.title, 'test me now');
  });

  test('with no annotation the row keeps the name it had', () async {
    // `agy` writes `annotations/<id>.pbtxt` only on a rename, so a conversation
    // nobody named has none. Saying nothing is the honest answer; the summary
    // preview is not a name and is not written here.
    writeStore(title: 'ignored');
    File(p.join(storeHome, 'annotations', '$conversation.pbtxt')).deleteSync();
    final ref = container();
    addTearDown(ref.dispose);

    await ref.read(cliStoreSyncRunnerProvider)();

    expect(SessionDao(db).getById('s1')!.title, 'New session');
  });
}
