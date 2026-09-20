/// `sessions.list` in the **Explorer's own order**, with the project identity,
/// pin and missing-folder facts the phone draws its groups from.
///
/// The mobile ordering bug this pins: the phone used to receive whatever order
/// the DAO happened to return (creation order across every project at once),
/// so a list that reads top-to-bottom on the desktop arrived shuffled.
library;

import 'package:karmashala_store/database.dart';
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
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/launch.dart';
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

  /// The newest evidence the app holds per session, as the presence seam
  /// reports it — the one reading the walk both orders by and sends.
  final activeAt = <String, DateTime>{};

  setUp(() {
    missing.clear();
    activeAt.clear();
    db = AppDatabase.memory();
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        remoteDeliveryStageProvider.overrideWithValue((id) async => null),
        remoteApprovalEvidenceProvider.overrideWithValue((id) async => null),
        remoteSessionPresenceProvider.overrideWithValue(
          (id) => (note: null, lastSeen: activeAt[id]),
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

  test('within a row: most recently active first, not most recently '
      'created', () {
    seedEnvironment();
    seedProject('p', r'C:\work\p');
    seedRepository('r', 'p', r'C:\work\p\repo');
    seedSession(
      'fresh-row',
      repositoryId: 'r',
      createdAt: DateTime.utc(2026, 6),
    );
    seedSession('old-row', repositoryId: 'r', createdAt: DateTime.utc(2026, 1));
    activeAt['old-row'] = DateTime.utc(2026, 8, 31, 9);

    // The phone shows "exactly as the host ordered them", so this walk is the
    // phone's order: a week-old session that answered this morning belongs
    // above one started in June that has done nothing.
    expect(listedIds(), ['old-row', 'fresh-row']);
  });

  test('a session we hold no reading for lists below every one we do', () {
    seedEnvironment();
    seedProject('p', r'C:\work\p');
    seedRepository('r', 'p', r'C:\work\p\repo');
    seedSession('silent', repositoryId: 'r', createdAt: DateTime.utc(2026, 8));
    seedSession('ancient', repositoryId: 'r', createdAt: DateTime.utc(2026, 1));
    activeAt['ancient'] = DateTime.utc(2020);

    expect(listedIds(), ['ancient', 'silent']);
  });

  test('the row carries the reading it was ordered by', () {
    seedEnvironment();
    seedProject('p', r'C:\work\p');
    seedRepository('r', 'p', r'C:\work\p\repo');
    seedSession('s1', repositoryId: 'r', createdAt: DateTime.utc(2026, 1));
    activeAt['s1'] = DateTime.utc(2026, 8, 31, 9);

    final row = container
        .read(remoteHostBindingsProvider)
        .listSessions()
        .single;

    // `lastActivityAt` is what the phone draws its age from, and it is the same
    // value the walk sorted by — a phone can never be handed a list ordered by
    // something it cannot see.
    expect(row.lastActivityAt, '2026-08-31T09:00:00.000Z');
  });

  test('a session with no reading falls back to its own birthday, never to '
      'now', () {
    seedEnvironment();
    seedProject('p', r'C:\work\p');
    seedRepository('r', 'p', r'C:\work\p\repo');
    seedSession('s1', repositoryId: 'r', createdAt: DateTime.utc(2026, 1, 2));

    final row = container
        .read(remoteHostBindingsProvider)
        .listSessions()
        .single;

    expect(row.lastActivityAt, '2026-01-02T00:00:00.000Z');
    expect(row.createdAt, '2026-01-02T00:00:00.000Z');
  });

  test('imported history is dated by its own file, or not at all', () {
    seedEnvironment();
    seedProject('p', r'C:\work\p');
    seedRepository('r', 'p', r'C:\work\p\repo');
    ImportedSessionDao(db).insertIfAbsent(
      ImportedSession(
        id: 'undated',
        repositoryId: 'r',
        cli: 'mystery',
        externalId: 'x2',
        environmentId: 'windows',
        filePath: r'C:\nowhere\x2.jsonl',
        storeHome: r'C:\nowhere',
        isSubagent: false,
        preview: 'no mtime',
        createdAt: now,
      ),
    );

    final row = container
        .read(remoteHostBindingsProvider)
        .listSessions()
        .single;

    // §19: a file we could not date is sent as nothing, never as its import
    // time dressed up as activity.
    expect(row.lastActivityAt, isNull);
  });
}
