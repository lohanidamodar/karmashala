/// `sessions.list` in the **Explorer's own order**, with the project identity,
/// pin and missing-folder facts the phone draws its groups from.
///
/// The mobile ordering bug this pins: the phone used to receive whatever order
/// the DAO happened to return (creation order across every project at once),
/// so a list that reads top-to-bottom on the desktop arrived shuffled.
library;

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/discovery.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/projects/domain/project.dart';
import 'package:karmashala/src/features/remote/application/remote_bindings.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session.dart';
import 'package:karmashala/src/features/sessions/domain/session_launch.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../terminal/fake_instance.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  final now = DateTime.utc(2026, 8, 31, 10);

  /// Directories reported as gone, so nothing here touches a filesystem.
  final missing = <String>{};

  setUp(() {
    missing.clear();
    db = AppDatabase.memory();
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        remoteDeliveryStageProvider.overrideWithValue((id) async => null),
        remoteApprovalEvidenceProvider.overrideWithValue((id) async => null),
        remoteSessionPresenceProvider.overrideWithValue(
          (id) => (note: null, lastSeen: null),
        ),
        // The two filesystem/git-shaped lookups, stubbed: a list must never
        // stat a disk or start git in a test.
        remoteFolderMissingProvider.overrideWithValue(
          (path) => missing.contains(path.path),
        ),
        remoteCheckoutBranchProvider.overrideWithValue((path) => null),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  EnvironmentPath path(String p) =>
      EnvironmentPath(environmentId: 'windows', path: p);

  void seedEnvironment() {
    ExecutionEnvironmentDao(db).upsert(
      ExecutionEnvironment(
        id: 'windows',
        kind: EnvironmentKind.windowsNative,
        name: 'Windows',
        createdAt: now,
      ),
    );
    AgentInstallationDao(db).insert(
      AgentInstallation(
        id: 'i1',
        agentId: 'mystery',
        executable: path(r'C:\bin\mystery.exe'),
        createdAt: now,
      ),
    );
  }

  void seedProject(String id, String root) {
    ProjectDao(
      db,
    ).insert(Project(id: id, name: id, root: path(root), createdAt: now));
  }

  void seedRepository(String id, String projectId, String at) {
    RepositoryDao(db).insert(
      Repository(
        id: id,
        projectId: projectId,
        name: id,
        path: path(at),
        createdAt: now,
      ),
    );
  }

  void seedSession(
    String id, {
    required String repositoryId,
    DateTime? createdAt,
    String? parentSessionId,
    String? worktree,
  }) {
    SessionDao(db).insert(
      Session(
        id: id,
        repositoryId: repositoryId,
        agentInstallationId: 'i1',
        title: id,
        useWorktree: worktree != null,
        worktree: worktree == null ? null : path(worktree),
        status: SessionStatus.running,
        createdAt: createdAt ?? now,
        surface: SessionSurface.external,
        parentSessionId: parentSessionId,
      ),
    );
  }

  List<String> listedIds() => [
    for (final row in container.read(remoteHostBindingsProvider).listSessions())
      row.sessionId,
  ];

  test('projects come in Explorer order — pinned first', () {
    seedEnvironment();
    seedProject('alpha', r'C:\work\alpha');
    seedProject('beta', r'C:\work\beta');
    seedRepository('r-alpha', 'alpha', r'C:\work\alpha\repo');
    seedRepository('r-beta', 'beta', r'C:\work\beta\repo');
    seedSession('a1', repositoryId: 'r-alpha');
    seedSession('b1', repositoryId: 'r-beta');

    expect(listedIds(), ['a1', 'b1']);

    container
        .read(settingsControllerProvider.notifier)
        .togglePinnedProject('beta');

    expect(listedIds(), [
      'b1',
      'a1',
    ], reason: 'the phone must read the desktop tree top to bottom');
  });

  test('repositories come in path order, deepest row wins the session', () {
    seedEnvironment();
    seedProject('hub', r'C:\work\hub');
    // Deliberately inserted out of path order.
    seedRepository('z', 'hub', r'C:\work\hub\zebra');
    seedRepository('a', 'hub', r'C:\work\hub\apple');
    seedSession('inZebra', repositoryId: 'z');
    seedSession('inApple', repositoryId: 'a');

    expect(listedIds(), ['inApple', 'inZebra']);
  });

  test('within a row: pinned first, then newest, with children under their '
      'parent', () {
    seedEnvironment();
    seedProject('p', r'C:\work\p');
    seedRepository('r', 'p', r'C:\work\p\repo');
    seedSession('old', repositoryId: 'r', createdAt: DateTime.utc(2026, 1, 1));
    seedSession('new', repositoryId: 'r', createdAt: DateTime.utc(2026, 6, 1));
    seedSession(
      'child-of-old',
      repositoryId: 'r',
      createdAt: DateTime.utc(2026, 2, 1),
      parentSessionId: 'old',
    );

    // Newest lineage first; a child follows the session it came from.
    expect(listedIds(), ['new', 'old', 'child-of-old']);

    container
        .read(settingsControllerProvider.notifier)
        .togglePinnedSession('old');

    expect(listedIds(), ['old', 'child-of-old', 'new']);
  });

  test('imported history interleaves by when it was last touched', () {
    seedEnvironment();
    seedProject('p', r'C:\work\p');
    seedRepository('r', 'p', r'C:\work\p\repo');
    seedSession('native', repositoryId: 'r', createdAt: DateTime.utc(2026, 3));
    ImportedSessionDao(db).insertIfAbsent(
      ImportedSession(
        id: 'imported',
        repositoryId: 'r',
        cli: 'mystery',
        externalId: 'x1',
        environmentId: 'windows',
        filePath: r'C:\nowhere\x1.jsonl',
        storeHome: r'C:\nowhere',
        isSubagent: false,
        preview: 'old chat',
        createdAt: now,
        updatedAt: DateTime.utc(2026, 7),
      ),
    );

    expect(listedIds(), ['imported', 'native']);
  });

  test('rows carry project identity, the pin, and the sub-path', () {
    seedEnvironment();
    seedProject('p', r'C:\work\p');
    seedRepository('r', 'p', r'C:\work\p\repo');
    seedSession('s1', repositoryId: 'r');
    container
        .read(settingsControllerProvider.notifier)
        .togglePinnedSession('s1');

    final row = container
        .read(remoteHostBindingsProvider)
        .listSessions()
        .single;

    expect(row.projectId, 'p');
    expect(row.projectName, 'p');
    expect(row.projectPath, r'C:\work\p');
    expect(row.pinned, isTrue);
    expect(row.subPath, 'repo');
    expect(row.folderMissing, isFalse);
    expect(row.worktree, isNull);
  });

  test('a session in a worktree names it, and a gone folder is flagged', () {
    seedEnvironment();
    seedProject('p', r'C:\work\p');
    seedRepository('r', 'p', r'C:\work\p\repo');
    seedSession('s1', repositoryId: 'r', worktree: r'C:\work\p\wt-thing');
    missing.add(r'C:\work\p\wt-thing');

    final row = container
        .read(remoteHostBindingsProvider)
        .listSessions()
        .single;

    expect(row.worktree, r'C:\work\p\wt-thing');
    expect(row.subPath, 'wt-thing');
    expect(row.folderMissing, isTrue);
    // The single-session lookup answers with the same facts.
    expect(
      container.read(remoteHostBindingsProvider).sessionById('s1')?.worktree,
      r'C:\work\p\wt-thing',
    );
  });

  test('nothing is ever dropped: a session with no project row still '
      'lists', () {
    seedEnvironment();
    // A repository whose project row is gone. Foreign keys forbid writing
    // that, which is the point: this is the corrupted-database shape the
    // fallback exists for, so it is seeded the only way it can occur.
    db.execute('PRAGMA foreign_keys = OFF;');
    seedRepository('orphan', 'no-such-project', r'C:\elsewhere\repo');
    seedSession('lost', repositoryId: 'orphan');
    db.execute('PRAGMA foreign_keys = ON;');
    seedProject('p', r'C:\work\p');
    seedRepository('r', 'p', r'C:\work\p\repo');
    seedSession('found', repositoryId: 'r');

    // Placed rows first, then whatever the walk could not reach.
    expect(listedIds(), ['found', 'lost']);
    expect(
      container.read(remoteHostBindingsProvider).listSessions().last.projectId,
      isNull,
      reason: 'an unknown project is named as unknown, never invented',
    );
  });

  test('every session appears exactly once', () {
    seedEnvironment();
    seedProject('p', r'C:\work\p');
    seedRepository('r', 'p', r'C:\work\p\repo');
    for (var i = 0; i < 5; i++) {
      seedSession('s$i', repositoryId: 'r');
    }

    final ids = listedIds();
    expect(ids, hasLength(5));
    expect(ids.toSet(), hasLength(5));
  });
}
