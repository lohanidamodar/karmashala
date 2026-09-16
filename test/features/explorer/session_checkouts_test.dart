import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/checkout.dart';
import 'package:karmashala/src/features/explorer/application/checkout_picker.dart';
import 'package:karmashala/src/features/explorer/application/session_context.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/checkout_probe_queue.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **What the checkout picker offers, and what it costs to offer it.**
///
/// The owner's rule for the right-hand panel: "explorer should list only
/// sessions; the sidebar should list the worktrees the currently active session
/// is working on". The picker used to answer with every checkout the project
/// holds, ordered by path — which for the owner's `popupbits` project is 69
/// rows, one of which is the answer, on a provider that is read again on every
/// tab switch.
///
/// Ranking that list was only half an answer. The owner's shape is **two
/// levels**: the picker offers *parent repositories* — the clones — and the
/// worktrees appear in the panel body underneath whichever one you chose. Level
/// one is short by construction, because a project has a handful of clones
/// however many `wt-*` directories hang off them. So these tests pin both: what
/// the picker leaves out, and that leaving it out never costs a git process the
/// panel had not already paid for.
///
/// Counted, not timed, the way `test/features/terminal/scale_curve_test.dart`
/// argues for. The unit is the **git subprocess**: the whole point of ranking
/// the list from records the database already holds is that it stays free.
void main() {
  const hubPath = r'C:\src\demo';
  const appPath = r'C:\src\demo\projects\app';
  const relayPath = r'C:\src\demo\projects\wt-relay';
  const inboxPath = r'C:\src\demo\projects\wt-inbox';
  const otherPath = r'C:\src\other';

  late AppDatabase db;
  late FakeCommandRunner git;
  late ProviderContainer container;

  /// Checkouts `git status` reports a changed file in, decided per test.
  var dirty = <String>{};

  EnvironmentPath at(String path) =>
      EnvironmentPath(environmentId: 'windows', path: path);

  String dirOf(CommandRequest request) =>
      request.arguments.length > 1 ? request.arguments[1] : '';

  /// Repository path -> the family `git worktree list` reports there, main
  /// worktree first. Empty means git answers nothing, which is the state every
  /// test that does not care about worktrees runs in.
  var families = <String, List<String>>{};

  CommandResult respond(CommandRequest request) {
    final verb = request.arguments.skip(2).toList();
    if (verb.length > 1 && verb.first == 'worktree' && verb[1] == 'list') {
      final family = families[dirOf(request)] ?? const <String>[];
      return CommandResult(
        exitCode: 0,
        stdout: [
          for (final path in family)
            'worktree ${path.replaceAll(r'\', '/')}\nbranch refs/heads/main\n',
        ].join(),
        stderr: '',
      );
    }
    if (verb.isNotEmpty && verb.first == 'status') {
      // Two formats for two calls: `statusWithBranch` asks for
      // `--porcelain=v2 --branch`, and `status` for a bare v1 file list.
      final changed = dirty.contains(dirOf(request))
          ? const ['lib/main.dart']
          : const <String>[];
      return CommandResult(
        exitCode: 0,
        stdout: verb.contains('--branch')
            ? porcelainV2(upstream: 'origin/main', modified: changed)
            : changed.map((path) => ' M $path\n').join(),
        stderr: '',
      );
    }
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  void insertAllCheckouts() {
    RepositoryDao(db)
      ..insert(repository(id: 'hub', name: 'demo', path: hubPath))
      ..insert(repository(id: 'app', name: 'app', path: appPath))
      ..insert(repository(id: 'relay', name: 'wt-relay', path: relayPath))
      ..insert(repository(id: 'inbox', name: 'wt-inbox', path: inboxPath));
  }

  void insertSession(
    String id, {
    String repositoryId = 'hub',
    String? worktree,
    String? workingDirectory,
  }) => SessionDao(db).insert(
    Session(
      id: id,
      repositoryId: repositoryId,
      agentInstallationId: 'a1',
      title: 'Work',
      useWorktree: worktree != null,
      worktree: worktree == null ? null : at(worktree),
      workingDirectory: workingDirectory == null ? null : at(workingDirectory),
      status: SessionStatus.running,
      createdAt: testTime,
    ),
  );

  /// A subagent of [parent] that recorded [directory] as the place it runs.
  void subagent(String id, String parent, {String? directory}) =>
      SessionDao(db).insert(
        Session(
          id: id,
          repositoryId: 'hub',
          agentInstallationId: 'a1',
          title: 'Subagent $id',
          useWorktree: false,
          workingDirectory: directory == null ? null : at(directory),
          status: SessionStatus.running,
          createdAt: testTime,
          parentSessionId: parent,
          parentLink: SessionLink.spawn,
        ),
      );

  /// Warms `checkoutDeliveryProvider` and keeps it alive, which is what an
  /// Explorer row watching a checkout does in the app.
  Future<void> measure(String path) async {
    final provider = checkoutDeliveryProvider(Checkout(at(path)));
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(subscription.close);
    await container.read(provider.future);
  }

  setUp(() {
    dirty = <String>{};
    families = <String, List<String>>{};
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project(id: 'p1', name: 'Demo', path: hubPath));
    AgentInstallationDao(db).insert(agentInstallation());
    git = FakeCommandRunner(responder: respond);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: git),
        ),
        // Selecting a project kicks off a CLI-store scan; nothing here tests
        // import.
        autoImportRunnerProvider.overrideWithValue(
          (repos) async => const ImportSummary(),
        ),
        deliveryPollIntervalProvider.overrideWithValue(Duration.zero),
        probeGateProvider.overrideWithValue(headlessProbeGate),
        gitFilesProvider.overrideWithValue(noGitFiles),
      ],
    );
    addTearDown(container.dispose);
  });
  tearDown(() => db.close());

  /// The panel following [sessionId], which is what a tab switch does.
  void follow(String sessionId) =>
      container.read(sessionContextProvider).follow(sessionId);

  List<String> offered() =>
      container.read(projectCheckoutsProvider).map((r) => r.id).toList();

  List<String> sessions() =>
      container.read(sessionCheckoutsProvider).map((r) => r.id).toList();

  group("the session's checkouts lead the list", () {
    test('a recorded directory first, then where the subagents work', () {
      // The strongest record the session has is its own directory, so it opens
      // the list however busy its subagents are; the checkouts they named come
      // next, and the launch-time repository — a guess, not a record — trails
      // them.
      insertAllCheckouts();
      insertSession('s1', workingDirectory: appPath);
      subagent('sub-1', 's1', directory: relayPath);
      subagent('sub-2', 's1', directory: inboxPath);
      follow('s1');

      expect(sessions(), ['app', 'inbox', 'relay', 'hub']);
      expect(offered(), ['app', 'inbox', 'relay', 'hub']);
    });

    test('a session that only its subagents locate leads with theirs', () {
      // The owner's own shape: the shell stays in the hub and the agents move.
      // The hub is still where the session is, so it stays in the group — last,
      // because a launch directory is the weakest thing here.
      insertAllCheckouts();
      insertSession('s1');
      subagent('sub-1', 's1', directory: relayPath);
      subagent('sub-2', 's1', directory: inboxPath);
      follow('s1');

      expect(sessions(), ['inbox', 'relay', 'hub']);
      expect(offered(), ['inbox', 'relay', 'hub', 'app']);
    });

    test('a worktree session leads with the worktree the app cut it', () {
      insertAllCheckouts();
      insertSession('s1', worktree: relayPath);
      follow('s1');

      expect(sessions(), ['relay', 'hub']);
      expect(offered().first, 'relay');
    });

    test('the checkout with uncommitted work outranks a quiet sibling', () async {
      // The same rank the default checkout is chosen by: changes, then how many
      // subagents named it, then the path. Ranking the group by anything else
      // would let the panel's first offer disagree with the panel's default.
      insertAllCheckouts();
      insertSession('s1');
      subagent('sub-1', 's1', directory: inboxPath);
      subagent('sub-2', 's1', directory: relayPath);
      dirty = {relayPath};
      await measure(inboxPath);
      await measure(relayPath);
      follow('s1');

      // Without the change rank the path would have put inbox first.
      expect(sessions(), ['relay', 'inbox', 'hub']);
    });

    test('the order does not move when nothing has moved', () {
      // Read twice, and by two consumers: a list that reshuffles on rebuild is
      // a menu whose rows move under the cursor.
      insertAllCheckouts();
      insertSession('s1');
      subagent('sub-1', 's1', directory: relayPath);
      subagent('sub-2', 's1', directory: inboxPath);
      follow('s1');

      final first = offered();
      container.read(sessionsRevisionProvider.notifier).bump();
      expect(offered(), first);
      expect(offered(), first);
    });
  });

  group('what the list still has to reach', () {
    test('every checkout in the project, once', () {
      // Nothing has run `git worktree list` here, so nothing is classified —
      // and an unclassified checkout is offered. "We have not asked git yet"
      // is not "this is a worktree", and a picker that hid a clone on a guess
      // would leave the user unable to reach it at all.
      insertAllCheckouts();
      insertSession('s1', workingDirectory: relayPath);
      follow('s1');

      expect(offered().toSet(), {'hub', 'app', 'relay', 'inbox'});
      expect(offered(), hasLength(4));
    });

    test('nothing followed: the plain path order it always had', () {
      insertAllCheckouts();
      container.read(selectedRepositoryIdProvider.notifier).select('hub');

      expect(sessions(), isEmpty);
      expect(offered(), ['hub', 'app', 'inbox', 'relay']);
    });

    test('never another project, however the session wandered', () {
      // Offering another project's clones would move the Explorer's tree out
      // from under the user — the same confinement the default already has.
      insertAllCheckouts();
      ProjectDao(db).insert(project(id: 'p2', name: 'Other', path: otherPath));
      RepositoryDao(db).insert(
        repository(
          id: 'other',
          projectId: 'p2',
          name: 'other',
          path: otherPath,
        ),
      );
      insertSession('s1', workingDirectory: appPath);
      subagent('sub-1', 's1', directory: otherPath);
      follow('s1');

      expect(offered(), isNot(contains('other')));
      expect(container.read(selectedProjectIdProvider), 'p1');
    });
  });

  group('the picker is parent repositories, worktrees are level two', () {
    /// `app` is a clone with two linked worktrees beside it; `hub` is a clone
    /// of its own. This is the owner's shape in miniature.
    void withFamilies() {
      insertAllCheckouts();
      families = {
        hubPath: [hubPath],
        appPath: [appPath, relayPath, inboxPath],
      };
    }

    /// Keeps `checkoutLabelsProvider` alive, which is what the panel beside
    /// the picker does. The picker reads that answer and never asks for it.
    Future<void> classify() async {
      final provider = checkoutLabelsProvider('p1');
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      await container.read(provider.future);
    }

    test('a linked worktree is not offered in the picker', () async {
      withFamilies();
      insertSession('s1', workingDirectory: relayPath);
      follow('s1');
      await classify();

      // `wt-relay` is where the session is actually working, and it is still
      // not a picker row: it belongs under `app` at level two. `app` leads
      // *because* the session is in one of its worktrees — the parent is what
      // a two-level picker has to select for the second level to hold the
      // answer.
      expect(offered(), ['app', 'hub']);
    });

    test('classifying costs one git worktree list per family', () async {
      withFamilies();
      container.read(selectedRepositoryIdProvider.notifier).select('hub');
      await classify();

      // Four recorded checkouts, two families. The command reports the whole
      // family wherever it is run, so asking once per row would be three
      // wasted processes on a 9p path.
      expect(
        git.requests
            .where(
              (r) => r.arguments.skip(2).take(2).join(' ') == 'worktree list',
            )
            .length,
        2,
      );
    });

    test(
      'the selected repository lists its own worktrees, and only those',
      () async {
        withFamilies();
        container.read(selectedRepositoryIdProvider.notifier).select('app');

        final worktrees = await container.read(
          selectedCheckoutWorktreesProvider.future,
        );

        // The main worktree is dropped — it *is* the selected repository, and
        // repeating it as a child of itself is how the old tree drew one
        // checkout twice.
        expect(worktrees.map((w) => canonicalPathKey(w.path.path)), [
          canonicalPathKey(relayPath),
          canonicalPathKey(inboxPath),
        ]);
        expect(
          git.requests
              .where(
                (r) => r.arguments.skip(2).take(2).join(' ') == 'worktree list',
              )
              .length,
          1,
          reason: 'level two asked about more than the one repository chosen',
        );
      },
    );

    test('a clone with no worktrees says so, rather than failing', () async {
      withFamilies();
      container.read(selectedRepositoryIdProvider.notifier).select('hub');

      expect(
        await container.read(selectedCheckoutWorktreesProvider.future),
        isEmpty,
      );
    });
  });

  group('what it costs', () {
    /// The owner's real number: one rescan took `popupbits` from 1 recorded
    /// checkout to 69.
    const scale = 69;

    void seedManyCheckouts() {
      RepositoryDao(
        db,
      ).insert(repository(id: 'hub', name: 'demo', path: hubPath));
      for (var i = 1; i < scale; i++) {
        RepositoryDao(db).insert(
          repository(
            id: 'wt-$i',
            name: 'wt-$i',
            path:
                r'C:\src\demo\projects\wt-'
                '$i',
          ),
        );
      }
    }

    test('69 checkouts, and the picker starts no git at all', () {
      // The rule `_changeRank` is written to: this provider reads caches other
      // people filled and never fills one itself. Asking would be a `git
      // status` per candidate on a path that runs on every tab switch.
      seedManyCheckouts();
      insertSession('s1');
      subagent('sub-1', 's1', directory: r'C:\src\demo\projects\wt-7');
      subagent('sub-2', 's1', directory: r'C:\src\demo\projects\wt-31');
      follow('s1');

      final offers = offered();
      // ignore: avoid_print
      print(
        'PICKER-COST checkouts=$scale offered=${offers.length} '
        'session=${sessions().length} git=${git.requests.length}',
      );
      expect(offers, hasLength(scale));
      expect(offers.take(3), ['wt-31', 'wt-7', 'hub']);
      expect(
        git.requests,
        isEmpty,
        reason: 'the picker ran git to decide what to offer',
      );
    });

    test(
      'classified, 69 checkouts collapse to the clones they hang off',
      () async {
        // The same 69 rows, once `git worktree list` has said what they are: 68
        // of them are worktrees of the hub, so the picker is one row and the
        // worktrees move to level two under it.
        seedManyCheckouts();
        families = {
          hubPath: [
            hubPath,
            for (var i = 1; i < scale; i++)
              r'C:\src\demo\projects\wt-'
                  '$i',
          ],
        };
        insertSession('s1');
        subagent('sub-1', 's1', directory: r'C:\src\demo\projects\wt-7');
        follow('s1');

        final labels = checkoutLabelsProvider('p1');
        final subscription = container.listen(labels, (_, _) {});
        addTearDown(subscription.close);
        await container.read(labels.future);
        final classifying = git.requests.length;

        final offers = offered();
        // ignore: avoid_print
        print(
          'PICKER-COST-CLASSIFIED checkouts=$scale offered=${offers.length} '
          'git_to_classify=$classifying',
        );

        expect(offers, ['hub']);
        // One `git worktree list`, not 69: the command reports the whole family
        // wherever it is run, and every one of these rows is in one family.
        expect(classifying, 1);

        // Level two holds what the picker no longer does.
        container.read(selectedRepositoryIdProvider.notifier).select('hub');
        final worktrees = await container.read(
          selectedCheckoutWorktreesProvider.future,
        );
        expect(worktrees, hasLength(scale - 1));
      },
    );

    test('a tab switch re-reads it without starting one either', () {
      seedManyCheckouts();
      insertSession('s1');
      insertSession('s2', workingDirectory: r'C:\src\demo\projects\wt-7');
      subagent('sub-1', 's1', directory: r'C:\src\demo\projects\wt-31');
      follow('s1');
      offered();
      final warm = git.requests.length;

      follow('s2');
      expect(offered().first, 'wt-7');
      expect(git.requests.length, warm);
      expect(git.requests, isEmpty);
    });
  });
}
