import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_host/src/data/data_service.dart';
import 'package:karmashala_host/src/git/server_git.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../mcp/tools/repo_tool_fixture.dart';

/// The server's git for its clients (slice 3b), driven the way a client
/// drives it — requests through a [DataSession], answered when done — over
/// real repositories in a temp folder.
void main() {
  late RepoToolFixture f;
  late ServerGit git;
  late DataSession client;
  late List<DataChange> told;
  late String app;
  late String appId;
  late Set<String> hosted;

  Future<R> ask<R>(DataRequest<R> request) async =>
      (await client.handleLater(request)).value;

  Future<DataRefused> refusal(DataRequest<Object?> request) async {
    try {
      await client.handleLater(request);
    } on DataRefused catch (refused) {
      return refused;
    }
    fail('${request.kind} was not refused');
  }

  CheckoutRef at(String path) => CheckoutRef.at(f.here(path));

  List<CheckoutTouched> touches() => told.whereType<CheckoutTouched>().toList();

  setUp(() {
    f = RepoToolFixture();
    app = f.repository(f.path('work/app'));
    appId = f
        .project('Work', f.path('work'), found: [app])
        .repositories
        .single
        .id;
    hosted = {};
    git = ServerGit(
      database: f.database,
      data: f.data,
      reach: f.reach,
      worktrees: f.worktrees,
      folders: f.folders,
      hostsSession: hosted.contains,
      livePaneDirectories: () => const [],
      clock: () => RepoToolFixture.now,
      onItsOwn: false,
    )..attach();
    told = [];
    client = f.data.open((batch) => told.addAll(batch.changes));
    client.handle(const DataSubscribe());
  });

  tearDown(() async {
    await git.stop();
    client.close();
    f.dispose();
  });

  group('reads', () {
    test('status, changes and per-file counts of a checkout', () async {
      File(p.join(app, 'README.md')).writeAsStringSync('changed\n');
      File(p.join(app, 'new.txt')).writeAsStringSync('new\n');

      final status = await ask(GitStatusOf(at(app)));
      expect(status.branch, 'main');
      expect(
        {for (final c in status.changes) c.path: c.type},
        {
          'README.md': FileChangeType.modified,
          'new.txt': FileChangeType.untracked,
        },
      );
      expect(
        await ask(GitChangesOf(CheckoutRef.repository(appId))),
        hasLength(2),
      );
      final stats = await ask(GitFileDiffStats(at(app)));
      expect(stats['README.md'], const FileDiffStat(added: 1, removed: 1));
      expect(stats.containsKey('new.txt'), isFalse, reason: 'untracked');
    });

    test('a staged change reads in a diff against HEAD, not a bare one — '
        'what a row counts is what its tab can show', () async {
      File(p.join(app, 'README.md')).writeAsStringSync('staged\n');
      f.git(app, ['add', 'README.md']);

      expect(await ask(GitDiff(at(app), path: 'README.md')), isEmpty);
      expect(
        await ask(GitDiff(at(app), path: 'README.md', base: 'HEAD')),
        contains('+staged'),
      );
      expect(
        await ask(GitDiff(at(app), path: 'README.md', staged: true)),
        contains('+staged'),
      );
    });

    test('an untracked file is drawn whole; a tracked one never is', () async {
      File(p.join(app, 'new.txt')).writeAsStringSync('fresh\n');
      expect(
        await ask(GitDiffUntracked(at(app), 'new.txt')),
        contains('+fresh'),
      );
      expect(await ask(GitDiffUntracked(at(app), 'README.md')), isEmpty);
    });

    test('a quoted path is one name from status to the pathspec', () async {
      File(p.join(app, 'héllo.txt')).writeAsStringSync('a\n');
      f.git(app, ['add', '.']);
      f.git(app, ['commit', '-q', '-m', 'quoted']);
      File(p.join(app, 'héllo.txt')).writeAsStringSync('b\n');

      final change = (await ask(GitChangesOf(at(app)))).single;
      expect(change.path, 'héllo.txt');
      expect(
        (await ask(GitFileDiffStats(at(app))))[change.path],
        const FileDiffStat(added: 1, removed: 1),
      );
      expect(
        await ask(GitDiff(at(app), path: change.path, base: 'HEAD')),
        contains('+b'),
      );
    });

    test('log, branch, HEAD, rev-parse and blob fingerprints', () async {
      final log = await ask(GitLog(at(app), limit: 5));
      expect(log.single.subject, 'first');
      expect(await ask(GitBranch(at(app))), 'main');
      expect(await ask(GitHead(at(app))), 'main');
      expect(
        await ask(GitRevParse(at(app), 'refs/heads/main')),
        log.single.sha,
      );
      expect(await ask(GitRevParse(at(app), 'refs/heads/nope')), isNull);
      final shas = await ask(GitBlobShas(at(app), ['README.md', 'gone.txt']));
      expect(shas.keys, ['README.md']);
    });

    test('against a base, and on which remote branches', () async {
      f.origin(app);
      f.git(app, ['checkout', '-q', '-b', 'work']);
      File(p.join(app, 'w.txt')).writeAsStringSync('w\n');
      f.git(app, ['add', '.']);
      f.git(app, ['commit', '-q', '-m', 'work']);

      expect(
        await ask(GitAheadBehind(at(app), base: 'main')),
        const AheadBehind(ahead: 1, behind: 0),
      );
      expect(
        await ask(GitRemoteBranchesContaining(at(app), 'HEAD')),
        isEmpty,
        reason: 'the commit exists only here',
      );
      expect(
        await ask(GitRemoteBranchesContaining(at(app), 'main')),
        contains('origin/main'),
      );
    });

    test('origin facts come from the clone; no remote is an answer', () async {
      expect(await ask(GitOriginFacts(at(app))), RepositoryOrigin.none);
      final bare = f.origin(app);
      final origin = await ask(GitOriginFacts(at(app)));
      expect(origin.url, bare);
      expect(origin.head, 'origin/main');
      expect(await ask(GitMergeInProgress(at(app))), isFalse);
    });

    test('presence from the filesystem, many at once', () async {
      final plain = f.path('plain');
      Directory(plain).createSync();
      final presences = await ask(GitPresenceOf([f.here(app), f.here(plain)]));
      expect(presences, [GitPresence.repository, GitPresence.notARepository]);
    });

    test('delivery: a worktree measured against the repository it came '
        'from', () async {
      final wt = f.path('work/.karmashala-worktrees/app-one');
      f.git(app, ['worktree', 'add', '-q', '-b', 'one', wt]);
      File(p.join(wt, 'x.txt')).writeAsStringSync('x\n');
      f.git(wt, ['add', '.']);
      f.git(wt, ['commit', '-q', '-m', 'x']);

      final repo = await ask(GitDelivery(at(app)));
      expect(repo.branch, 'main');
      expect(repo.hasRemote, isFalse);

      final delivery = await ask(GitDelivery(at(wt), repository: f.here(app)));
      expect(delivery.branch, 'one');
      expect(delivery.baseBranch, 'main', reason: 'no origin/HEAD to use');
      expect(delivery.aheadOfBase, 1);
      expect(delivery.dirtyFiles, 0);
    });

    test('a folder that is not a repository is refused as that', () async {
      final plain = f.path('plain');
      Directory(plain).createSync();
      final refused = await refusal(GitStatusOf(at(plain)));
      expect(refused.code, DataRefusalCode.failed);
      expect(refused.message.toLowerCase(), contains('not a git repository'));
    });

    test(
      'an unknown checkout id and an unknown environment are refused',
      () async {
        expect(
          (await refusal(
            GitStatusOf(const CheckoutRef.repository('nope')),
          )).code,
          DataRefusalCode.notFound,
        );
        final elsewhere = await refusal(
          GitStatusOf(
            const CheckoutRef.at(
              EnvironmentPath(environmentId: 'mars', path: '/x'),
            ),
          ),
        );
        expect(elsewhere.code, DataRefusalCode.failed);
        expect(elsewhere.message, contains('mars'));
      },
    );
  });

  group('writes', () {
    test('stage, unstage, commit and discard — each told as a touch of the '
        'recorded checkout', () async {
      File(p.join(app, 'README.md')).writeAsStringSync('one\n');
      File(p.join(app, 'extra.txt')).writeAsStringSync('x\n');

      await ask(GitStage(at(app), const ['README.md']));
      expect(
        (await ask(
          GitChangesOf(at(app)),
        )).firstWhere((c) => c.path == 'README.md').staged,
        isTrue,
      );
      final touched = touches().single;
      expect(touched.cause, CheckoutTouchCause.gitWrite);
      expect(touched.repositoryId, appId);
      expect(Checkout(touched.directory), Checkout(f.here(app)));

      await ask(GitUnstage(at(app), const ['README.md']));
      await ask(GitCommitStaged(at(app), 'everything', all: true));
      expect(
        (await ask(GitLog(at(app), limit: 1))).single.subject,
        'everything',
      );
      expect(await ask(GitChangesOf(at(app))), isEmpty);

      File(p.join(app, 'README.md')).writeAsStringSync('oops\n');
      File(p.join(app, 'junk.txt')).writeAsStringSync('junk\n');
      await ask(
        GitDiscard(
          at(app),
          tracked: const ['README.md'],
          untracked: const ['junk.txt'],
        ),
      );
      expect(await ask(GitChangesOf(at(app))), isEmpty);
      expect(File(p.join(app, 'junk.txt')).existsSync(), isFalse);
      expect(touches(), hasLength(4));
    });

    test(
      'a blank commit message is refused, and nothing is committed',
      () async {
        final refused = await refusal(GitCommitStaged(at(app), '  '));
        expect(refused.code, DataRefusalCode.invalid);
        expect(await ask(GitLog(at(app), limit: 5)), hasLength(1));
      },
    );

    test('merge, a conflicted merge undone, and a branch moved back', () async {
      final first = (await ask(GitLog(at(app), limit: 1))).single.sha;
      f.git(app, ['checkout', '-q', '-b', 'side']);
      File(p.join(app, 'README.md')).writeAsStringSync('side\n');
      f.git(app, ['commit', '-q', '-am', 'side']);
      f.git(app, ['checkout', '-q', 'main']);

      await ask(GitMerge(at(app), 'side'));
      expect(await ask(GitRevParse(at(app), 'HEAD')), isNot(first));

      await ask(GitMoveBranch(at(app), branch: 'side', sha: first));
      expect(await ask(GitRevParse(at(app), 'refs/heads/side')), first);

      // A conflict: both sides change one line.
      f.git(app, ['checkout', '-q', '-b', 'other', first]);
      File(p.join(app, 'README.md')).writeAsStringSync('other\n');
      f.git(app, ['commit', '-q', '-am', 'other']);
      f.git(app, ['checkout', '-q', 'main']);
      final conflict = await refusal(GitMerge(at(app), 'other', commit: true));
      expect(conflict.code, DataRefusalCode.failed);
      expect(await ask(GitMergeInProgress(at(app))), isTrue);
      expect(await ask(GitAbortMerge(at(app))), isTrue);
      expect(await ask(GitMergeInProgress(at(app))), isFalse);
    });

    test('a push with nowhere to go is refused in git\'s words', () async {
      final refused = await refusal(GitPush(at(app)));
      expect(
        refused.code,
        anyOf(DataRefusalCode.failed, DataRefusalCode.invalid),
      );
      expect(
        touches(),
        isNotEmpty,
        reason: 'a write is told even when it fails',
      );
    });
  });

  group('worktrees', () {
    test('made, listed, labelled and removed, each told', () async {
      final created = await ask(
        WorktreeCreate(
          at(app),
          creationId: 'c1',
          worktreeName: 'feature',
          branch: 'feature',
        ),
      );
      expect(created.worktree.branch, 'feature');
      expect(Directory(created.worktree.path.path).existsSync(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(
        told.whereType<WorktreeCreationChanged>().map((c) => c.creationId),
        everyElement('c1'),
      );
      expect(told.whereType<WorktreeCreationChanged>(), isNotEmpty);
      expect(
        touches().map((t) => t.cause),
        contains(CheckoutTouchCause.worktree),
      );

      final listed = await ask(WorktreesOf(at(app)));
      expect(listed.map((w) => w.branch), ['main', 'feature']);

      final wtId = f
          .project(
            'Wt',
            created.worktree.path.path,
            found: [created.worktree.path.path],
          )
          .repositories
          .single
          .id;
      final labels = await ask(WorktreeLabels([appId, wtId]));
      expect(labels[appId]!.isWorktree, isFalse);
      expect(labels[wtId]!.isWorktree, isTrue);
      expect(labels[wtId]!.ownerRepositoryId, appId);
      expect(labels[wtId]!.branch, 'feature');

      await ask(WorktreeRemove(at(app), worktree: created.worktree.path));
      expect(Directory(created.worktree.path.path).existsSync(), isFalse);
      expect(await ask(WorktreesOf(at(app))), hasLength(1));
    });

    test('a creation that launches an agent is settled by the asker', () async {
      await ask(
        WorktreeCreate(
          at(app),
          creationId: 'c2',
          worktreeName: 'agent',
          branch: 'agent',
          launchesAgent: true,
        ),
      );
      expect(git.creations.isLive('c2'), isTrue);
      await ask(const WorktreeAgentSettled('c2'));
      expect(git.creations.isLive('c2'), isFalse);
      // Settling or cancelling one it no longer has is harmless.
      await ask(const WorktreeAgentSettled('c2', error: 'late'));
      await ask(const WorktreeCreationCancel('nobody'));
    });

    test('two creations may not share an id', () async {
      await ask(
        WorktreeCreate(
          at(app),
          creationId: 'same',
          worktreeName: 'a',
          branch: 'a',
          launchesAgent: true,
        ),
      );
      final refused = await refusal(
        WorktreeCreate(
          at(app),
          creationId: 'same',
          worktreeName: 'b',
          branch: 'b',
        ),
      );
      expect(refused.code, DataRefusalCode.invalid);
    });
  });

  test('an agent\'s turn ending touches where its session works', () {
    f.session('s1', appId);
    git.turnEnded('s1');
    final touched = touches().single;
    expect(touched.cause, CheckoutTouchCause.turnEnded);
    expect(touched.repositoryId, appId);
    git.turnEnded('no-such-session');
    expect(touches(), hasLength(1));
  });

  test('a delivery reading keeps the clone\'s canonical identity', () async {
    f.git(app, ['remote', 'add', 'origin', 'git@github.com:acme/app.git']);
    await ask(GitDelivery(at(app)));
    expect(
      RepositoryDao(f.database).getById(appId)!.canonicalId,
      canonicalRepositoryId('git@github.com:acme/app.git'),
    );
  });

  group('a project\'s folders', () {
    test('created over a folder with two repositories', () async {
      final a = f.repository(f.path('two/a'));
      f.repository(f.path('two/b'));
      final created = await ask(
        ProjectFoldersCreate(projectName: 'Two', root: f.here(f.path('two'))),
      );
      expect(created.repositories, hasLength(2));
      expect(
        created.repositories.map((r) => Checkout(r.path)),
        contains(Checkout(f.here(a))),
      );
    });

    test('a rescan finds a repository cloned in after', () async {
      f.repository(f.path('two/a'));
      final created = await ask(
        ProjectFoldersCreate(projectName: 'Two', root: f.here(f.path('two'))),
      );
      f.repository(f.path('two/late'));
      final added = await ask(ProjectRescan(created.project.id));
      expect(added.map((r) => r.name), contains('late'));
    });

    test(
      'a folder that is not there is refused, and nothing written',
      () async {
        final refused = await refusal(
          ProjectFoldersCreate(
            projectName: 'Ghost',
            root: f.here(f.path('ghost')),
          ),
        );
        expect(refused.code, DataRefusalCode.failed);
      },
    );
  });

  test('a server with no git work refuses it as unavailable', () async {
    await git.stop();
    final refused = await refusal(GitStatusOf(at(app)));
    expect(refused.code, DataRefusalCode.unavailable);
  });

  test('the local delivery reading travels whole', () {
    const request = GitDelivery(CheckoutRef.repository('r'));
    const reading = SessionDelivery(branch: 'b', dirtyFiles: 2, aheadOfBase: 1);
    final back = request.resultFromJson(request.resultToJson(reading));
    expect(back.branch, 'b');
    expect(back.dirtyFiles, 2);
    expect(back.aheadOfBase, 1);
  });
}
