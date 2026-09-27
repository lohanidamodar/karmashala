import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_host/src/mcp/tools/checkout_reach.dart';
import 'package:karmashala_host/src/mcp/tools/session_liveness.dart';
import 'package:karmashala_host/src/mcp/tools/workspace_tool_set.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session/session.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'repo_tool_fixture.dart';

/// `list_checkouts`, `project_rescan` and `delivery_status`, run by the
/// server over real git repositories.
///
/// The rule these are really about: **a reading Karmashala could not take is
/// reported as "not recorded", never as zero.** A model that reads
/// `unpushed: 0` from a failed git call concludes the branch is pushed.
void main() {
  late RepoToolFixture fixture;
  late WorkspaceToolSet tools;
  late Set<String> running;

  /// `demo/app` (a clone with an origin) and its worktree `demo/app-feature`
  /// on `feature/login`, recorded as the project `demo`.
  late String app;
  late String feature;
  late String projectId;
  late String appId;
  late String featureId;

  setUp(() {
    fixture = RepoToolFixture();
    running = {};
    tools = WorkspaceToolSet(
      fixture.context,
      reach: fixture.reach,
      folders: fixture.folders,
      worktreesOf: fixture.worktrees.list,
      liveness: SessionLiveness(running.contains),
    );
    app = fixture.repository(fixture.path('demo/app'));
    fixture.origin(app);
    feature = fixture.path('demo/app-feature');
    fixture.git(app, ['worktree', 'add', '-q', '-b', 'feature/login', feature]);
    final created = fixture.project(
      'demo',
      fixture.path('demo'),
      found: [app, feature],
    );
    projectId = created.project.id;
    appId = created.repositories.firstWhere((r) => r.path.path == app).id;
    featureId = created.repositories
        .firstWhere((r) => r.path.path == feature)
        .id;
  });

  tearDown(() => fixture.dispose());

  Future<({Object? value, String? error})> call(
    String tool, [
    Map<String, dynamic> arguments = const {},
    String? caller,
  ]) => RepoToolFixture.outcome(tools.call(tool, arguments, caller));

  group('list_checkouts', () {
    test('names every checkout with the branch git reported', () async {
      final answer = await call('list_checkouts', {'projectId': projectId});
      final checkouts = ((answer.value! as Map)['checkouts']! as List<Object?>)
          .cast<Map<String, Object?>>();

      expect(checkouts, hasLength(2));
      final main = checkouts.firstWhere((c) => c['repositoryId'] == appId);
      final worktree = checkouts.firstWhere(
        (c) => c['repositoryId'] == featureId,
      );
      expect(main['branch'], 'main');
      expect(main['isWorktree'], isFalse);
      expect(worktree['branch'], 'feature/login');
      expect(
        worktree['isWorktree'],
        isTrue,
        reason: 'git lists the main worktree first; the rest are worktrees',
      );
      expect(main['environmentId'], localHostEnvironmentId);
    });

    test('a branch git could not report reads "not recorded"', () async {
      // Not a repository any more: every `git worktree list` fails.
      Directory(p.join(app, '.git')).deleteSync(recursive: true);
      File(p.join(feature, '.git')).deleteSync();

      final answer = await call('list_checkouts', {'projectId': projectId});
      final checkouts = (answer.value! as Map)['checkouts']! as List<Object?>;

      // The checkouts are still listed — we know they exist. What we do not
      // know is what branch they are on, and that is said rather than guessed.
      expect(checkouts, hasLength(2));
      for (final checkout in checkouts.cast<Map<String, Object?>>()) {
        expect(checkout['branch'], 'not recorded');
        expect(checkout['isWorktree'], isNull);
      }
    });

    test('names the sessions recorded as working in each checkout', () async {
      fixture.session('s1', featureId, title: 'Login', worktree: feature);

      final answer = await call('list_checkouts', {'projectId': projectId});
      final checkouts = ((answer.value! as Map)['checkouts']! as List<Object?>)
          .cast<Map<String, Object?>>();
      final here = checkouts.firstWhere((c) => c['repositoryId'] == featureId);
      expect(here['sessionsWorkingHere'], [
        {'sessionId': 's1', 'title': 'Login', 'status': 'created'},
      ]);
    });

    test('a session working in the checkout itself is an occupant', () async {
      fixture.session(
        'in-app',
        appId,
        title: 'Working in the checkout itself',
        status: SessionStatus.running,
        workingDirectory: app,
      );

      final answer = await call('list_checkouts', {'projectId': projectId});
      final checkouts = ((answer.value! as Map)['checkouts']! as List<Object?>)
          .cast<Map<String, Object?>>();
      final byId = {for (final c in checkouts) c['repositoryId']: c};
      expect(
        (byId[appId]!['sessionsWorkingHere']! as List)
            .cast<Map<String, Object?>>()
            .map((s) => s['sessionId']),
        ['in-app'],
      );
      // "No session recorded here" is an empty list — which the tool's own
      // description says is not a promise the checkout is free.
      expect(byId[featureId]!['sessionsWorkingHere'], isEmpty);
    });

    test('an unknown project is an error', () async {
      final answer = await call('list_checkouts', {'projectId': 'ghost'});
      expect(answer.error, contains('ghost'));
    });

    test('a missing projectId says where the ids come from', () async {
      final answer = await call('list_checkouts');
      expect(answer.error, contains('list_projects'));
    });

    test('a project on an SSH host is read over the server\'s own '
        'connection', () async {
      _sshProject(fixture);
      final answer = await call('list_checkouts', {'projectId': 'remote'});
      final checkouts = ((answer.value! as Map)['checkouts']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(checkouts.single['environmentId'], 'box');
      expect(checkouts.single['branch'], 'main');
    });
  });

  group('project_rescan', () {
    test('records a checkout added from the command line', () async {
      final second = fixture.repository(fixture.path('demo/second'));

      final answer = await call('project_rescan', {'projectId': projectId});

      final result = answer.value! as Map<String, Object?>;
      expect(result['count'], 1);
      final checkouts = (result['checkouts']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(checkouts.single['path'], second);
      expect(
        RepositoryDao(fixture.database).getByProject(projectId),
        hasLength(3),
      );
    });

    test('an unknown project is an error, not an empty success', () async {
      final answer = await call('project_rescan', {'projectId': 'ghost'});
      expect(answer.error, contains('no longer in the workspace'));
    });

    test('a project on an SSH host is scanned with find on the box', () async {
      _sshProject(fixture);
      fixture.repository(fixture.path('box/second'));

      final answer = await call('project_rescan', {'projectId': 'remote'});

      final result = answer.value! as Map<String, Object?>;
      expect(result['count'], 1);
      final added = RepositoryDao(
        fixture.database,
      ).getByProject('remote').firstWhere((r) => r.id != 'rr');
      expect(added.path.environmentId, 'box');
      expect(added.path.path, fixture.path('box/second'));
    }, testOn: 'posix');
  });

  group('delivery_status', () {
    test('reads the checkout: branch, base, and nothing owed', () async {
      fixture.session('s1', appId);

      final result =
          (await call('delivery_status', {'sessionId': 's1'})).value!
              as Map<String, Object?>;

      expect(result['branch'], 'main');
      expect(result['baseBranch'], 'origin/main');
      expect(result['upstream'], 'origin/main');
      expect(result['dirtyFiles'], 0);
      expect(result['aheadOfBase'], 0);
      expect(result['unpushed'], 0);
      expect(result['agentRunning'], isFalse);
      expect(result['stage'], isA<String>());
    });

    test('counts dirty files and commits the base does not have', () async {
      fixture.session('s1', featureId, worktree: feature);
      File(p.join(feature, 'new.txt')).writeAsStringSync('x');
      File(p.join(feature, 'README.md')).writeAsStringSync('changed\n');
      fixture.git(feature, ['add', 'README.md']);
      fixture.git(feature, ['commit', '-q', '-m', 'second']);
      File(p.join(feature, 'README.md')).writeAsStringSync('again\n');

      final result =
          (await call('delivery_status', {'sessionId': 's1'})).value!
              as Map<String, Object?>;

      expect(result['branch'], 'feature/login');
      expect(result['hasWorktree'], isTrue);
      expect(result['dirtyFiles'], 2);
      expect(result['aheadOfBase'], 1);
      expect(result['behindBase'], 0);
    });

    test('unknown readings say so instead of reading as zero', () async {
      fixture.session('s1', appId);
      Directory(p.join(app, '.git')).deleteSync(recursive: true);

      final result =
          (await call('delivery_status', {'sessionId': 's1'})).value!
              as Map<String, Object?>;

      // Every one of these is null at the source because git failed. Zero
      // would mean "nothing outstanding", which is the opposite of true here.
      expect(result['dirtyFiles'], 'not recorded');
      expect(result['unpushed'], 'not recorded');
      expect(result['aheadOfBase'], 'not recorded');
      expect(result['behindBase'], 'not recorded');
      expect(result['branch'], 'not recorded');
      expect(result['pullRequest'], startsWith('not recorded'));
    });

    test('offers the same actions the delivery strip would', () async {
      fixture.session('s1', appId);

      final result =
          (await call('delivery_status', {'sessionId': 's1'})).value!
              as Map<String, Object?>;
      final actions = (result['actions']! as List<Object?>)
          .cast<Map<String, Object?>>();

      expect(actions, isNotEmpty);
      for (final action in actions) {
        expect(action['label'], isA<String>());
        // An unavailable action carries its reason, so an agent is never
        // left guessing why it cannot push.
        if (action['available'] == false) {
          expect(action['unavailableBecause'], isA<String>());
        }
      }
    });

    test('a session the server runs is an agent running', () async {
      fixture.session('s1', appId);
      running.add('s1');

      final result =
          (await call('delivery_status', {'sessionId': 's1'})).value!
              as Map<String, Object?>;
      expect(result['agentRunning'], isTrue);
    });

    test('defaults to the calling session', () async {
      fixture.session('s1', appId);

      final result =
          (await call('delivery_status', const {}, 's1')).value!
              as Map<String, Object?>;
      expect(result['sessionId'], 's1');
      expect(result['title'], 'Work');
    });

    test('an unattributed caller must name a session', () async {
      final answer = await call('delivery_status');
      expect(answer.error, contains('not running inside a session'));
    });

    test('an unknown session is an error', () async {
      final answer = await call('delivery_status', {'sessionId': 'ghost'});
      expect(answer.error, contains('No session with id ghost'));
    });
  });

  test('select_checkout is not the server\'s: it moves the app\'s screen', () {
    expect(tools.schemas.map((s) => s['name']), [
      'list_checkouts',
      'project_rescan',
      'delivery_status',
    ]);
  });
}

/// A project `remote` with one checkout on an SSH host — a "box" that is
/// this machine, so the checkout is a real repository under `box/app`.
void _sshProject(RepoToolFixture fixture) {
  final at = RepoToolFixture.now.toIso8601String();
  final root = fixture.path('box');
  final app = fixture.repository(fixture.path('box/app'));
  fixture.database.execute(
    'INSERT INTO execution_environments (id, kind, name, created_at) '
    "VALUES ('box', 'ssh', 'Build box', ?);",
    [at],
  );
  fixture.database.execute(
    'INSERT INTO projects (id, name, root_environment_id, root_path, '
    "created_at) VALUES ('remote', 'Remote', 'box', ?, ?);",
    [root, at],
  );
  fixture.database.execute(
    'INSERT INTO repositories (id, project_id, name, environment_id, path, '
    "created_at) VALUES ('rr', 'remote', 'app', 'box', ?, ?);",
    [app, at],
  );
  // A server that reaches no SSH would not answer for it; this one does.
  expect(CheckoutReach(fixture.database).answers('box'), isFalse);
  expect(fixture.reach.answers('box'), isTrue);
}
