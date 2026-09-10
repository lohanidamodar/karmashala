import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/fanout/application/fanout_service.dart';
import 'package:karmashala/src/features/mcp/workspace_tools.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_repositories_service.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_repository_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session.dart';
import 'package:karmashala/src/features/sessions/domain/session_checkouts.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/sessions/presentation/session_repositories_bar.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import '../../support/fixtures.dart';
import '../fanout/fanout_harness.dart' as fanout;

/// A worktree isolates one repository. A multi-repo session has more than one.
///
/// `SessionLauncher` creates a worktree for `request.repository` and links every
/// other repository as a row pointing at its single main checkout, so two
/// concurrent worktree sessions on a multi-repo project are isolated in the
/// primary and share every other checkout — one working tree, one index, one
/// branch between them. Fan-out always uses worktrees, so it meets this first
/// and hardest.
///
/// **The sharing is kept and made visible**, and
/// `SessionRepositoriesService.checkoutsFor` carries the four-count argument for
/// why. What these tests pin is the second half of that sentence: that the app
/// now says which checkouts are shared, to the person through the chip bar's
/// tooltip and to the agent through `list_checkouts`. A silent version of this
/// arrangement is the bug; a stated one is a design.
void main() {
  late AppDatabase db;
  late SessionRepositoriesService service;
  late SessionRepositoryDao links;

  /// A project with three checkouts, which is the shape this is about: an `app`
  /// each session worktrees, and `api` and `docs` that nobody does.
  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project(id: 'p1'));
    RepositoryDao(db)
      ..insert(repository(id: 'r-app', projectId: 'p1', name: 'app'))
      ..insert(
        repository(
          id: 'r-api',
          projectId: 'p1',
          name: 'api',
          path: r'C:\src\demo\api',
        ),
      )
      ..insert(
        repository(
          id: 'r-docs',
          projectId: 'p1',
          name: 'docs',
          path: r'C:\src\demo\docs',
        ),
      );
    AgentInstallationDao(db).insert(agentInstallation());
    links = SessionRepositoryDao(db);
    service = SessionRepositoriesService(
      sessionDao: SessionDao(db),
      repositoryDao: RepositoryDao(db),
      linkDao: links,
    );
  });
  tearDown(() => db.close());

  /// One worktree session spanning `app` (its own) plus whichever others.
  void worktreeSession(
    String id, {
    String worktree = r'C:\src\.karmashala-worktrees\app-1',
    List<String> alsoSpanning = const ['r-api'],
  }) {
    SessionDao(db).insert(
      Session(
        id: id,
        repositoryId: 'r-app',
        agentInstallationId: 'a1',
        title: 'Session $id',
        useWorktree: true,
        worktree: EnvironmentPath(environmentId: 'windows', path: worktree),
        workingDirectory: EnvironmentPath(
          environmentId: 'windows',
          path: worktree,
        ),
        status: SessionStatus.running,
        createdAt: testTime,
      ),
    );
    links.link(id, 'r-app', role: SessionRepositoryRole.primary);
    for (final extra in alsoSpanning) {
      links.link(id, extra);
    }
  }

  group('two concurrent worktree sessions on a multi-repo project', () {
    setUp(() {
      worktreeSession('s1', worktree: r'C:\src\.karmashala-worktrees\app-1');
      worktreeSession('s2', worktree: r'C:\src\.karmashala-worktrees\app-2');
    });

    test('are isolated in the primary repository', () {
      for (final id in ['s1', 's2']) {
        final primary = service
            .checkoutsFor(id)
            .firstWhere((checkout) => checkout.isPrimary);
        expect(primary.repositoryId, 'r-app');
        expect(primary.isolation, CheckoutIsolation.isolated);
        expect(primary.sharedWith, isEmpty);
        // Nothing to warn about: git guarantees this one.
        expect(primary.note, isNull);
      }
    });

    test('and share the secondary — which is the finding, stated', () {
      final api = service
          .checkoutsFor('s1')
          .firstWhere((checkout) => checkout.repositoryId == 'r-api');
      expect(api.isPrimary, isFalse);
      expect(api.isolation, CheckoutIsolation.shared);
      // The directory is the repository itself, not a worktree of it: an
      // additional link carries no directory of its own.
      expect(api.directory.path, r'C:\src\demo\api');
      expect(api.note, contains('shared checkout'));
    });

    test('the other session is named, not merely implied', () {
      // `s2` is linked to `api` too, but the app only *knows* a session is in a
      // directory when that session's row records it — and a secondary link
      // records nothing. So this is the honest answer for the shared row: the
      // structural warning, without a claim about who is in it.
      final api = service
          .checkoutsFor('s1')
          .firstWhere((checkout) => checkout.repositoryId == 'r-api');
      expect(api.sharedWith, isEmpty);
      expect(api.note, isNot(contains('working in it now')));

      // Two sessions that genuinely record the same directory *are* named. This
      // is the case a `useWorktree: false` session hits, and it is the same
      // collision wearing the primary's hat.
      SessionDao(db).insert(
        Session(
          id: 's3',
          repositoryId: 'r-app',
          agentInstallationId: 'a1',
          title: 'In the repository itself',
          useWorktree: false,
          workingDirectory: const EnvironmentPath(
            environmentId: 'windows',
            path: r'C:\src\demo\app',
          ),
          status: SessionStatus.running,
          createdAt: testTime,
        ),
      );
      links.link('s3', 'r-app', role: SessionRepositoryRole.primary);
      SessionDao(db).insert(
        Session(
          id: 's4',
          repositoryId: 'r-app',
          agentInstallationId: 'a1',
          title: 'Also in the repository itself',
          useWorktree: false,
          workingDirectory: const EnvironmentPath(
            environmentId: 'windows',
            // The other spelling of the same directory: forward slashes, as
            // `git worktree list` reports them. One tree, two spellings.
            path: 'C:/src/demo/app/',
          ),
          status: SessionStatus.running,
          createdAt: testTime,
        ),
      );
      links.link('s4', 'r-app', role: SessionRepositoryRole.primary);

      final shared = service
          .checkoutsFor('s3')
          .firstWhere((checkout) => checkout.isPrimary);
      expect(shared.isolation, CheckoutIsolation.shared);
      expect(shared.sharedWith.map((s) => s.id), ['s4']);
      expect(shared.note, contains('Also in the repository itself'));
    });

    test('an archived session is not counted as still standing there', () {
      SessionDao(db).insert(
        Session(
          id: 's5',
          repositoryId: 'r-app',
          agentInstallationId: 'a1',
          title: 'Finished',
          useWorktree: false,
          workingDirectory: const EnvironmentPath(
            environmentId: 'windows',
            path: r'C:\src\demo\api',
          ),
          status: SessionStatus.completed,
          createdAt: testTime,
          archivedAt: testTime,
        ),
      );
      final api = service
          .checkoutsFor('s1')
          .firstWhere((checkout) => checkout.repositoryId == 'r-api');
      expect(api.sharedWith, isEmpty);
    });

    test('a row in another environment is not the same directory', () {
      ExecutionEnvironmentDao(db).upsert(wslEnv());
      SessionDao(db).insert(
        Session(
          id: 's6',
          repositoryId: 'r-app',
          agentInstallationId: 'a1',
          title: 'Same string, other machine',
          useWorktree: false,
          workingDirectory: const EnvironmentPath(
            environmentId: 'wsl:Ubuntu',
            path: r'C:\src\demo\api',
          ),
          status: SessionStatus.running,
          createdAt: testTime,
        ),
      );
      final api = service
          .checkoutsFor('s1')
          .firstWhere((checkout) => checkout.repositoryId == 'r-api');
      expect(api.sharedWith, isEmpty);
    });
  });

  group('fan-out with N candidates on a multi-repo project', () {
    /// Fan-out launches N sessions with `useWorktree: true` against one
    /// repository. What it never does is attach the project's other
    /// repositories — `FanOutService._launchOne` passes no
    /// `additionalRepositories` — so the candidates do not even *carry* the
    /// secondary checkouts. They can still reach them: `list_checkouts` lists
    /// every checkout in the project, and `terminal_open` takes any working
    /// directory. That gap is what the tool result below closes.
    setUp(() {
      for (var i = 1; i <= 4; i++) {
        worktreeSession(
          'cand-$i',
          worktree: r'C:\src\.karmashala-worktrees\app-cand-' '$i',
          alsoSpanning: const [],
        );
      }
    });

    test('every candidate is isolated in the repository it was fanned out on',
        () {
      final worktrees = <String>{};
      for (var i = 1; i <= 4; i++) {
        final checkouts = service.checkoutsFor('cand-$i');
        expect(checkouts, hasLength(1));
        expect(checkouts.single.isolation, CheckoutIsolation.isolated);
        worktrees.add(checkouts.single.directory.path);
      }
      expect(worktrees, hasLength(4));
    });

    test('and none of them is recorded in the project\'s other checkouts, so '
        'the shared ones read empty rather than crowded', () {
      for (final path in [r'C:\src\demo\api', r'C:\src\demo\docs']) {
        expect(
          sessionsWorkingIn(
            EnvironmentPath(environmentId: 'windows', path: path),
            excluding: '',
            among: SessionDao(db).getAll(),
          ),
          isEmpty,
        );
      }
    });

    test('list_checkouts names the occupants of each checkout', () async {
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);

      // Four candidates in four worktrees of `app`, and one ordinary session
      // working in `app` itself: the tool must distinguish them.
      SessionDao(db).insert(
        Session(
          id: 'in-app',
          repositoryId: 'r-app',
          agentInstallationId: 'a1',
          title: 'Working in the checkout itself',
          useWorktree: false,
          workingDirectory: const EnvironmentPath(
            environmentId: 'windows',
            path: r'C:\src\demo\app',
          ),
          status: SessionStatus.running,
          createdAt: testTime,
        ),
      );

      final result =
          await WorkspaceControlTools(container).call('list_checkouts', {
                'projectId': 'p1',
              })
              as Map<String, Object?>;
      final checkouts = (result['checkouts']! as List)
          .cast<Map<String, Object?>>();
      final byName = {
        for (final checkout in checkouts) checkout['name'] as String: checkout,
      };

      expect(
        (byName['app']!['sessionsWorkingHere']! as List)
            .cast<Map<String, Object?>>()
            .map((s) => s['sessionId']),
        ['in-app'],
      );
      // The candidates are in worktrees, which are not `repositories` rows
      // here, so they show up nowhere — and `api` and `docs` read empty, which
      // is what "no session recorded here" looks like. The tool's own
      // description says that is not a promise the checkout is free.
      for (final name in ['api', 'docs']) {
        expect(byName[name]!['sessionsWorkingHere'], isEmpty);
      }
    });
  });

  group('the real fan-out, measured rather than asserted', () {
    test('N candidates get N worktrees of the primary and no link to any '
        'other repository', () async {
      // The `fanout` harness is a real `SessionLauncher` over fake terminals
      // and a fake git, so worktree creation and the session rows are the
      // production code path. A second repository is added to the project it
      // builds — the multi-repo shape this whole file is about.
      final h = fanout.harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      RepositoryDao(h.db).insert(
        repository(id: 'r-api', name: 'api', path: r'C:\src\demo\api'),
      );

      final launched = await h.container
          .read(fanOutServiceProvider)
          .launch(
            repository: repository(),
            installations: [
              fanout.roverInstall,
              fanout.flakyInstall,
              fanout.secondRoverInstall,
            ],
            prompt: 'compare these',
          );
      expect(launched.started, hasLength(3));

      final linkDao = SessionRepositoryDao(h.db);
      final worktrees = <String>{};
      for (final result in launched.started) {
        final id = result.session.id;
        // Its own worktree of the primary…
        expect(result.session.worktree, isNotNull);
        worktrees.add(result.session.worktree!.path);
        // …and no link to anything else. Fan-out passes no
        // `additionalRepositories`, so a candidate does not even carry the
        // project's other checkouts — it can still reach them through
        // `list_checkouts` and its own shell, which is why that tool now names
        // who is standing in each.
        expect(linkDao.linksFor(id).map((l) => l.repositoryId), ['r1']);
        expect(linkDao.linksFor(id).single.isPrimary, isTrue);
      }
      expect(worktrees, hasLength(3), reason: 'three distinct worktrees');

      // And the secondary checkout nobody worktreed is recorded as holding
      // nobody, which is the honest answer and not a promise it is free.
      expect(
        sessionsWorkingIn(
          const EnvironmentPath(
            environmentId: 'windows',
            path: r'C:\src\demo\api',
          ),
          excluding: '',
          among: SessionDao(h.db).getAll(),
        ),
        isEmpty,
      );
    });

    test('each candidate is stamped with a port base of its own', () async {
      // The other half of parallel isolation, and the one a worktree cannot
      // give: two candidates running the same repository script must not both
      // bind the same port. Derived, so it survives a restart — and a
      // namespace rather than a lock, so this asserts distinctness for the
      // ids actually minted and claims nothing stronger.
      final h = fanout.harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final launched = await h.container
          .read(fanOutServiceProvider)
          .launch(
            repository: repository(),
            installations: [
              fanout.roverInstall,
              fanout.flakyInstall,
              fanout.secondRoverInstall,
            ],
            prompt: 'compare these',
          );
      final bases = {
        for (final result in launched.started)
          sessionPortBase(result.session.id),
      };
      expect(bases, hasLength(3));
    });
  });

  group('the chip bar says which checkouts are shared', () {
    testWidgets('a shared repository carries the warning and the session\'s '
        'own worktree does not', (tester) async {
      worktreeSession('s1');
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          selectedSessionIdProvider.overrideWith(
            () => _FixedSelection('s1'),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: SessionRepositoriesBar(sessionId: 's1')),
          ),
        ),
      );

      String? tooltipOf(String label) => tester
          .widgetList<InputChip>(find.byType(InputChip))
          .firstWhere((chip) => (chip.label as Text).data == label)
          .tooltip;

      expect(tooltipOf('app'), isNull);
      expect(tooltipOf('api'), contains('shared checkout'));
    });
  });
}

class _FixedSelection extends SelectedSessionController {
  _FixedSelection(this._id);
  final String _id;

  @override
  String? build() => _id;
}
