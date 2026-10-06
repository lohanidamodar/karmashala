import 'dart:io';

import 'package:karmashala_host/src/mcp/tools/session_liveness.dart';
import 'package:karmashala_host/src/mcp/tools/worktree_tool_set.dart';
import 'package:karmashala_projects/store.dart' show RepositoryDao;
import 'package:karmashala_session/session.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'repo_tool_fixture.dart';

/// Making a worktree and taking one away, run by the server over real git.
///
/// The removal half is the reason this file is careful. A worktree directory
/// is the only thing here that can hold work nothing else has a copy of, so
/// the tool refuses **in words** for every reading it does not like *and* for
/// every reading it could not take — and there is deliberately no argument
/// that overrides any of it. The rule encoded is the owner's own: a worktree
/// goes only once its branch is merged **and** pushed.
void main() {
  late RepoToolFixture fixture;
  late WorktreeToolSet tools;
  late Set<String> running;

  /// `demo/app`, recorded as the project `demo`'s one checkout.
  late String app;
  late String projectId;
  late String appId;

  setUp(() {
    fixture = RepoToolFixture();
    running = {};
    tools = WorktreeToolSet(
      fixture.context,
      reach: fixture.reach,
      folders: fixture.folders,
      worktrees: fixture.worktrees,
      liveness: SessionLiveness(running.contains),
    );
    app = fixture.repository(fixture.path('demo/app'));
  });

  tearDown(() => fixture.dispose());

  /// Records the project with [app] and, when given, [worktree] as its
  /// checkouts; answers the worktree's row id.
  String? record({String? worktree}) {
    final created = fixture.project(
      'demo',
      fixture.path('demo'),
      found: [app, ?worktree],
    );
    projectId = created.project.id;
    appId = created.repositories.firstWhere((r) => r.path.path == app).id;
    return worktree == null
        ? null
        : created.repositories.firstWhere((r) => r.path.path == worktree).id;
  }

  Future<({Object? value, String? error})> call(
    String tool,
    Map<String, dynamic> arguments,
  ) => RepoToolFixture.outcome(tools.call(tool, arguments, null));

  List<String> worktreePaths() => [
    for (final line
        in fixture.git(app, ['worktree', 'list', '--porcelain']).split('\n'))
      // git spells Windows paths with forward slashes.
      if (line.startsWith('worktree '))
        p.normalize(line.substring('worktree '.length).trim()),
  ];

  group('worktree_create', () {
    setUp(() => record());

    test('runs git worktree add and reports where it landed', () async {
      final answer = await call('worktree_create', {
        'repositoryId': appId,
        'name': 'mcp',
        'branch': 'feat/mcp',
      });

      expect(answer.error, isNull);
      final result = answer.value! as Map<String, Object?>;
      final expected = fixture.path('demo/.karmashala-worktrees/app-mcp');
      expect(result['path'], expected);
      expect(result['branch'], 'feat/mcp');
      expect(result['fromRepositoryId'], appId);
      expect(result['projectId'], projectId);
      expect(result['baseRef'], startsWith('not recorded'));
      expect((result['stages']! as Map)['outcome'], 'succeeded');
      expect(worktreePaths(), contains(expected));
      expect(
        fixture.git(expected, ['branch', '--show-current']).trim(),
        'feat/mcp',
      );
      // The worktree lands in a dot-folder a rescan skips, outside the
      // project's root when the root is the clone itself. It is recorded all
      // the same, so a session can be started in it and shows its branch.
      final id = result['repositoryId']! as String;
      expect(id, isNot(startsWith('not recorded')));
      final row = RepositoryDao(fixture.database).getById(id)!;
      expect(row.projectId, projectId);
      expect(row.path.path, expected);
    });

    test('a base ref is passed on when one is given', () async {
      fixture.git(app, ['branch', 'base']);
      final answer = await call('worktree_create', {
        'repositoryId': appId,
        'name': 'mcp',
        'branch': 'feat/mcp',
        'baseRef': 'base',
      });
      expect(answer.error, isNull);
      expect((answer.value! as Map)['baseRef'], 'base');
    });

    /// **A project with no git has no worktrees — that is absence, not
    /// error.** Asked for a worktree of a plain folder, git would answer with
    /// a `.git` the caller never mentioned; this says what was observed.
    test('a checkout that is not a repository is refused in words', () async {
      Directory(p.join(app, '.git')).deleteSync(recursive: true);

      final answer = await call('worktree_create', {
        'repositoryId': appId,
        'name': 'mcp',
        'branch': 'feat/mcp',
      });

      expect(answer.error, contains('not a Git repository'));
      expect(answer.error, contains(app));
    });

    test('a path a worktree already occupies is refused', () async {
      fixture.git(app, [
        'worktree',
        'add',
        '-q',
        '-b',
        'first',
        fixture.path('demo/.karmashala-worktrees/app-taken'),
      ]);

      final answer = await call('worktree_create', {
        'repositoryId': appId,
        'name': 'taken',
        'branch': 'feat/second',
      });

      expect(answer.error, contains('already a worktree'));
      expect(worktreePaths(), hasLength(2));
    });

    test('a branch that already exists is refused', () async {
      fixture.git(app, ['branch', 'existing']);
      final answer = await call('worktree_create', {
        'repositoryId': appId,
        'name': 'other',
        'branch': 'existing',
      });

      expect(answer.error, contains('existing already exists'));
      expect(worktreePaths(), hasLength(1));
    });

    test('a branch another worktree has out is refused', () async {
      final elsewhere = fixture.path('elsewhere');
      fixture.git(app, ['worktree', 'add', '-q', '-b', 'busy', elsewhere]);

      final answer = await call('worktree_create', {
        'repositoryId': appId,
        'name': 'other',
        'branch': 'busy',
      });

      expect(answer.error, contains('already checked out at $elsewhere'));
    });

    test('a name that is a path is refused before git sees it', () async {
      final answer = await call('worktree_create', {
        'repositoryId': appId,
        'name': '../escape',
        'branch': 'feat/x',
      });

      expect(answer.error, contains('one folder name'));
      expect(worktreePaths(), hasLength(1));
    });

    test('a branch git would not accept is refused before git sees it', () {
      expect(
        call('worktree_create', {
          'repositoryId': appId,
          'name': 'x',
          'branch': 'bad..name',
        }).then((a) => a.error),
        completion(contains('will not accept')),
      );
    });

    test('git\'s own refusal is reported in git\'s words', () async {
      final answer = await call('worktree_create', {
        'repositoryId': appId,
        'name': 'mcp',
        'branch': 'feat/mcp',
        'baseRef': 'no-such-ref',
      });

      expect(answer.error, isNotNull);
      expect(worktreePaths(), hasLength(1));
    });

    test('a checkout Karmashala never recorded is an error', () async {
      final answer = await call('worktree_create', {
        'repositoryId': 'ghost',
        'name': 'mcp',
        'branch': 'feat/mcp',
      });
      expect(answer.error, contains('No checkout with id ghost'));
    });

    test('a checkout on an SSH host gets its worktree over the server\'s '
        'own connection', () async {
      final box = _sshCheckout(fixture, projectId);
      final answer = await call('worktree_create', {
        'repositoryId': 'rr',
        'name': 'mcp',
        'branch': 'feat/mcp',
      });
      expect(answer.error, isNull);
      final result = answer.value! as Map<String, Object?>;
      expect(result['environmentId'], 'box');
      expect(result['branch'], 'feat/mcp');
      expect(fixture.git(box, ['worktree', 'list']), contains('feat/mcp'));
    }, testOn: 'posix');
  });

  group('worktree_remove', () {
    late String worktree;
    late String worktreeId;

    /// A worktree on `feature/login` beside `app`, with `main` pushed to an
    /// origin: clean, merged and pushed until a test says otherwise.
    void pushedWorktree() {
      fixture.origin(app);
      worktree = fixture.path('demo/app-feature');
      fixture.git(app, [
        'worktree',
        'add',
        '-q',
        '-b',
        'feature/login',
        worktree,
      ]);
      worktreeId = record(worktree: worktree)!;
    }

    test('removes a merged, pushed, clean worktree', () async {
      pushedWorktree();

      final answer = await call('worktree_remove', {
        'repositoryId': worktreeId,
      });

      expect(answer.error, isNull);
      final result = answer.value! as Map<String, Object?>;
      expect(result['removed'], isTrue);
      expect(result['branch'], 'feature/login');
      expect(result['baseBranch'], 'origin/main');
      expect(result['branchKept'], isTrue);
      expect(Directory(worktree).existsSync(), isFalse);
      expect(
        fixture.git(app, ['branch', '--list', 'feature/login']).trim(),
        isNotEmpty,
        reason: 'the branch is left alone',
      );
    });

    test('never passes --force, whatever it was asked', () async {
      pushedWorktree();
      // A locked worktree is one only --force would remove.
      fixture.git(app, ['worktree', 'lock', worktree]);

      final answer = await call('worktree_remove', {
        'repositoryId': worktreeId,
        'force': true,
      });

      expect(answer.error, contains('locked'));
      expect(Directory(worktree).existsSync(), isTrue);
    });

    test('refuses the main checkout', () async {
      pushedWorktree();
      final answer = await call('worktree_remove', {'repositoryId': appId});
      expect(answer.error, contains('main checkout'));
    });

    test('refuses uncommitted changes', () async {
      pushedWorktree();
      File(p.join(worktree, 'a.dart')).writeAsStringSync('x');

      final answer = await call('worktree_remove', {
        'repositoryId': worktreeId,
      });

      expect(answer.error, contains('uncommitted'));
      expect(Directory(worktree).existsSync(), isTrue);
    });

    test('refuses a branch that is not merged into its base', () async {
      pushedWorktree();
      File(p.join(worktree, 'a.dart')).writeAsStringSync('x');
      fixture.git(worktree, ['add', '.']);
      fixture.git(worktree, ['commit', '-q', '-m', 'work']);

      final answer = await call('worktree_remove', {
        'repositoryId': worktreeId,
      });

      expect(answer.error, contains('origin/main'));
      expect(answer.error, contains('1 commit '));
      expect(Directory(worktree).existsSync(), isTrue);
    });

    test('refuses a branch merged locally but never pushed', () async {
      // No origin: the base is the branch the main checkout has out, and
      // nothing outside this machine holds these commits.
      worktree = fixture.path('demo/app-feature');
      fixture.git(app, ['worktree', 'add', '-q', '-b', 'feature', worktree]);
      File(p.join(worktree, 'a.dart')).writeAsStringSync('x');
      fixture.git(worktree, ['add', '.']);
      fixture.git(worktree, ['commit', '-q', '-m', 'work']);
      fixture.git(app, ['merge', '-q', '--ff-only', 'feature']);
      worktreeId = record(worktree: worktree)!;

      final answer = await call('worktree_remove', {
        'repositoryId': worktreeId,
      });

      expect(answer.error, contains('Push first'));
      expect(Directory(worktree).existsSync(), isTrue);
    });

    test('refuses a reading it could not take', () async {
      // No origin and a detached main checkout: there is no base at all.
      worktree = fixture.path('demo/app-feature');
      fixture.git(app, ['worktree', 'add', '-q', '-b', 'feature', worktree]);
      fixture.git(app, ['checkout', '-q', '--detach']);
      worktreeId = record(worktree: worktree)!;

      final answer = await call('worktree_remove', {
        'repositoryId': worktreeId,
      });

      expect(answer.error, contains('not recorded'));
      expect(Directory(worktree).existsSync(), isTrue);
    });

    test('refuses while an agent is live in it', () async {
      pushedWorktree();
      fixture.session(
        's1',
        worktreeId,
        title: 'Login work',
        status: SessionStatus.running,
      );

      final answer = await call('worktree_remove', {
        'repositoryId': worktreeId,
      });

      expect(answer.error, contains('Login work'));
      expect(Directory(worktree).existsSync(), isTrue);
    });

    test('a session the server runs there counts as live', () async {
      pushedWorktree();
      fixture.session('s1', appId, title: 'Hosted', worktree: worktree);
      running.add('s1');

      final answer = await call('worktree_remove', {
        'repositoryId': worktreeId,
      });

      expect(answer.error, contains('Hosted'));
    });

    test('a checkout git will not describe is refused, not guessed', () async {
      final plain = fixture.path('demo/plain');
      Directory(plain).createSync(recursive: true);
      final created = fixture.project(
        'demo',
        fixture.path('demo'),
        found: [plain],
      );

      final answer = await call('worktree_remove', {
        'repositoryId': created.repositories.single.id,
      });

      expect(answer.error, contains('not recorded'));
      expect(Directory(plain).existsSync(), isTrue);
    });

    test('a checkout on an SSH host is judged by the server', () async {
      record();
      _sshCheckout(fixture, projectId);
      final answer = await call('worktree_remove', {'repositoryId': 'rr'});
      // The main checkout of its repository, read by git on the box.
      expect(answer.error, contains('main checkout'));
    });
  });
}

/// A checkout `rr` of [projectId] on an SSH host — a "box" that is this
/// machine, so it is a real repository; answers its folder.
String _sshCheckout(RepoToolFixture fixture, String projectId) {
  final at = RepoToolFixture.now.toIso8601String();
  final app = fixture.repository(fixture.path('box/app'));
  fixture.database.execute(
    'INSERT INTO execution_environments (id, kind, name, created_at) '
    "VALUES ('box', 'ssh', 'Build box', ?);",
    [at],
  );
  fixture.database.execute(
    'INSERT INTO repositories (id, project_id, name, environment_id, path, '
    "created_at) VALUES ('rr', ?, 'app', 'box', ?, ?);",
    [projectId, app, at],
  );
  return app;
}
