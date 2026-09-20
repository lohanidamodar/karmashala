import 'dart:convert';
import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/antigravity_attribution_service.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fixtures.dart';
import 'package:agent_cli/read.dart';

/// Learning which Antigravity conversation a session we launched is on.
///
/// `agy` mints its own id and will not accept one, so neither of the app's
/// existing routes works: there is no `--session-id` to pass, and every
/// conversation file looks alike from outside. Before this, an app-launched
/// Antigravity session was a phantom — a row with no CLI id, which nothing could
/// resume, rename or find again
///.
///
/// The rules themselves are `AntigravitySessionAttributor`'s and are tested in
/// `antigravity_session_resume_test.dart`. What is tested here is the service
/// that applies them to real rows: which rows it picks up, what it writes, and
/// the several different reasons it refuses.
void main() {
  late Directory tmp;
  late String storeHome;
  late AppDatabase db;
  late SessionDao dao;

  const conversation = 'df3c0708-1111-4222-8333-444455556666';
  const other = 'e921cb55-1111-4222-8333-444455556666';
  const repoPath = r'C:\src\demo\app';

  final launchedAt = testTime;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('karmashala_agy_attr_');
    storeHome = p.join(tmp.path, '.gemini', 'antigravity-cli');
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(
      db,
    ).insert(agentInstallation(agentId: AgentIds.antigravity));
    AgentInstallationDao(
      db,
    ).insert(agentInstallation(id: 'a2', agentId: AgentIds.claudeCode));
    dao = SessionDao(db);
  });
  tearDown(() {
    db.close();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps a handle on a database a failing test left open.
    }
  });

  /// A conversation file, timestamped relative to the launch.
  void writeConversation(String id, {Duration age = Duration.zero}) {
    final file = File(p.join(storeHome, 'conversations', '$id.db'))
      ..createSync(recursive: true)
      ..writeAsStringSync('not read by attribution');
    file.setLastModifiedSync(launchedAt.add(age));
  }

  void writeLastConversations(Map<String, String> byDirectory) {
    File(p.join(storeHome, 'cache', 'last_conversations.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(byDirectory));
  }

  void insert({
    String id = 's1',
    String installation = 'a1',
    String? externalId,
    String? directory = repoPath,
    String? paneId,
    SessionStatus status = SessionStatus.running,
  }) {
    dao.insert(
      Session(
        id: id,
        repositoryId: 'r1',
        agentInstallationId: installation,
        title: 'New session',
        useWorktree: false,
        workingDirectory: directory == null
            ? null
            : EnvironmentPath(environmentId: 'windows', path: directory),
        status: status,
        createdAt: launchedAt,
        externalSessionId: externalId,
        paneId: paneId,
      ),
    );
  }

  AntigravitySessionAttributionService service({
    Map<String, List<String>> paneTails = const {},
  }) => AntigravitySessionAttributionService(
    sessionDao: dao,
    installationDao: AgentInstallationDao(db),
    repositoryDao: RepositoryDao(db),
    agents: AgentRegistry.builtIn,
    locateStores: () async => [
      CliStore(
        environmentId: 'windows',
        homesByAgentId: {AgentIds.antigravity: storeHome},
      ),
    ],
    readPaneTail: (paneId, lines) => paneTails[paneId] ?? const [],
  );

  group('what it learns', () {
    test('the conversation the directory names, once it is new', () async {
      writeConversation(conversation, age: const Duration(seconds: 5));
      writeLastConversations({repoPath: conversation});
      insert();

      final attribution = service();
      expect(attribution.wantsStoreSweep, isTrue);
      expect(await attribution.attribute(), 1);
      expect(dao.getById('s1')!.externalSessionId, conversation);
      // And the row stops being a candidate, so the next slot costs nothing.
      expect(attribution.wantsStoreSweep, isFalse);
    });

    test('what the CLI printed in our own pane beats the store', () async {
      // §3.1: `agy` prints its own resume command as it exits. A line the agent
      // printed in our pane is not an inference about which conversation it
      // was, so it wins outright — here over a store entry naming another one.
      writeConversation(other, age: const Duration(seconds: 5));
      writeLastConversations({repoPath: other});
      insert(paneId: 'pane-1');

      final attribution = service(
        paneTails: {
          'pane-1': [
            'Resume with -c (or command below):',
            'agy --conversation=$conversation',
          ],
        },
      );
      expect(await attribution.attribute(), 1);
      expect(dao.getById('s1')!.externalSessionId, conversation);
    });
  });

  group('what it refuses, and why the reason differs', () {
    test(
      'a directory the store has never recorded a conversation for',
      () async {
        // The session was launched and never prompted: `agy` writes the entry on
        // the first message, so there is nothing to find.
        writeLastConversations({r'C:\elsewhere': other});
        insert();

        final attribution = service();
        expect(await attribution.attribute(), 0);
        expect(dao.getById('s1')!.externalSessionId, isNull);
        expect(attribution.reasonFor('s1'), contains('no conversation'));
      },
    );

    test('a conversation written before this session started', () async {
      writeConversation(conversation, age: const Duration(minutes: -5));
      writeLastConversations({repoPath: conversation});
      insert();

      final attribution = service();
      expect(await attribution.attribute(), 0);
      expect(dao.getById('s1')!.externalSessionId, isNull);
      expect(attribution.reasonFor('s1'), contains('earlier one'));
    });

    test('a conversation another session already holds', () async {
      writeConversation(conversation, age: const Duration(seconds: 5));
      writeLastConversations({repoPath: conversation});
      insert(id: 'held', externalId: conversation);
      insert(id: 's1');

      final attribution = service();
      expect(await attribution.attribute(), 0);
      expect(dao.getById('s1')!.externalSessionId, isNull);
      expect(attribution.reasonFor('s1'), contains('another session'));
    });

    test('two unattributed sessions in one directory', () async {
      // One entry, two candidates, and nothing to tell them apart: the store
      // records the directory, not the process. Attributing it to either would
      // be a coin toss whose losing side resumes somebody else's conversation.
      writeConversation(conversation, age: const Duration(seconds: 5));
      writeLastConversations({repoPath: conversation});
      insert(id: 's1');
      insert(id: 's2');

      final attribution = service();
      expect(await attribution.attribute(), 0);
      expect(dao.getById('s1')!.externalSessionId, isNull);
      expect(dao.getById('s2')!.externalSessionId, isNull);
      expect(attribution.reasonFor('s1'), contains('More than one session'));
    });
  });

  group('which rows it looks at', () {
    test('never one that already has an id', () async {
      writeConversation(other, age: const Duration(seconds: 5));
      writeLastConversations({repoPath: other});
      insert(externalId: conversation);

      final attribution = service();
      expect(attribution.wantsStoreSweep, isFalse);
      expect(await attribution.attribute(), 0);
      expect(dao.getById('s1')!.externalSessionId, conversation);
    });

    test('never another agent, whose store this is not', () async {
      writeConversation(conversation, age: const Duration(seconds: 5));
      writeLastConversations({repoPath: conversation});
      insert(installation: 'a2');

      final attribution = service();
      expect(attribution.wantsStoreSweep, isFalse);
      expect(await attribution.attribute(), 0);
      expect(dao.getById('s1')!.externalSessionId, isNull);
    });

    test('never an archived one', () async {
      writeConversation(conversation, age: const Duration(seconds: 5));
      writeLastConversations({repoPath: conversation});
      insert();
      dao.markArchived('s1', testTime);

      expect(service().wantsStoreSweep, isFalse);
      expect(await service().attribute(), 0);
    });

    test(
      'falls back to the repository when no directory was recorded',
      () async {
        // Rows written before schema v22 record no working directory; the
        // repository root is where the session would have been launched.
        writeConversation(conversation, age: const Duration(seconds: 5));
        writeLastConversations({repoPath: conversation});
        insert(directory: null);

        expect(await service().attribute(), 1);
        expect(dao.getById('s1')!.externalSessionId, conversation);
      },
    );
  });
}
