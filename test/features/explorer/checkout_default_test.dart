import 'package:karmashala/src/core/database/app_database.dart';
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
import 'package:karmashala/src/features/repositories/application/repository_providers.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// Which checkout the repository-scoped surfaces describe when nobody has
/// picked one.
///
/// The shape under test is the owner's own workspace, the same one
/// `test/app/shell/checkout_picker_test.dart` uses: a hub project whose work
/// happens in a clone three folders down and in the `wt-*` worktrees beside it.
/// Resolving "the deepest registered checkout containing the launch directory"
/// answers *the hub* for every session started there, which is the complaint.
void main() {
  const hubPath = r'C:\src\demo';
  const appPath = r'C:\src\demo\projects\app';
  const relayPath = r'C:\src\demo\projects\wt-relay';
  const inboxPath = r'C:\src\demo\projects\wt-inbox';
  const otherPath = r'C:\src\other';

  late AppDatabase db;
  late FakeCommandRunner git;
  late ProviderContainer container;

  /// Checkouts `git status` reports a changed file in. Read by [respond], so a
  /// test decides what git would have said before warming the cache.
  var dirty = <String>{};

  EnvironmentPath at(String path) =>
      EnvironmentPath(environmentId: 'windows', path: path);

  String dirOf(CommandRequest request) =>
      request.arguments.length > 1 ? request.arguments[1] : '';

  List<String> verbOf(CommandRequest request) =>
      request.arguments.skip(2).toList();

  CommandResult respond(CommandRequest request) {
    final verb = verbOf(request);
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
    // No remote, so nothing measures against `origin/HEAD` and one `git status`
    // is the whole cost of a checkout's delivery state.
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  void insertAllCheckouts() {
    RepositoryDao(db)
      ..insert(repository(id: 'hub', name: 'demo', path: hubPath))
      ..insert(repository(id: 'app', name: 'app', path: appPath))
      ..insert(repository(id: 'relay', name: 'wt-relay', path: relayPath))
      ..insert(repository(id: 'inbox', name: 'wt-inbox', path: inboxPath));
  }

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

  /// Warms `checkoutDeliveryProvider` for [path] and keeps it alive, which is
  /// what an Explorer row watching it does in the app.
  Future<void> measure(String path) async {
    final provider = checkoutDeliveryProvider(Checkout(at(path)));
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(subscription.close);
    await container.read(provider.future);
  }

  setUp(() {
    dirty = <String>{};
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
        // Selecting a project kicks off a CLI-store scan; nothing here is
        // testing import.
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

  String? follow(String sessionId) =>
      container.read(sessionContextProvider).follow(sessionId)?.id;

  group('the strongest signal a session has', () {
    test('a worktree session is described by its worktree', () {
      // The app cut this worktree for this session, so there is no guessing to
      // do. This is the answer the shipped rule already gave; it is pinned so
      // the new signals cannot take it away.
      insertAllCheckouts();
      insertSession('s1', worktree: relayPath);

      expect(follow('s1'), 'relay');
    });

    test('an adopted session is described where its agent actually ran', () {
      // A session started by hand in a terminal tab records the directory the
      // process is in (schema v22). That is an observation, and it outranks the
      // hub the row was created against.
      insertAllCheckouts();
      insertSession('s1', workingDirectory: appPath);

      expect(follow('s1'), 'app');
    });

    test('a session with neither follows its subagents into the sub-repo', () {
      // The owner's decisive observation: their own shell legitimately stays in
      // the hub, and it is the subagents that move.
      insertAllCheckouts();
      insertSession('s1');
      subagent('sub-1', 's1', directory: appPath);

      expect(follow('s1'), 'app');
    });

    test('a session with no signal at all lands where it landed before', () {
      insertAllCheckouts();
      insertSession('s1');

      expect(follow('s1'), 'hub');
    });

    test('a session no checkout contains keeps its own repository', () {
      // Paths are never compared across environments, so nothing contains this.
      insertAllCheckouts();
      SessionDao(db).insert(
        session(
          repositoryId: 'app',
          useWorktree: true,
          worktree: const EnvironmentPath(
            environmentId: 'wsl:Ubuntu',
            path: '/home/me/work',
          ),
        ),
      );

      expect(follow('s1'), 'app');
    });
  });

  group('when two signals disagree', () {
    test("the session's own directory outranks its subagents'", () {
      // The panel describes the session you are looking at, not the ones it
      // delegated to.
      insertAllCheckouts();
      insertSession('s1', workingDirectory: relayPath);
      subagent('sub-1', 's1', directory: appPath);
      subagent('sub-2', 's1', directory: appPath);

      expect(follow('s1'), 'relay');
    });

    test('a worktree outranks the subagents too', () {
      insertAllCheckouts();
      insertSession('s1', worktree: relayPath);
      subagent('sub-1', 's1', directory: appPath);

      expect(follow('s1'), 'relay');
    });

    test('subagents in two checkouts: the one with changes wins', () async {
      insertAllCheckouts();
      insertSession('s1');
      subagent('sub-1', 's1', directory: appPath);
      subagent('sub-2', 's1', directory: inboxPath);
      dirty = {inboxPath};
      await measure(appPath);
      await measure(inboxPath);

      final asked = git.requests.length;
      expect(follow('s1'), 'inbox');
      expect(
        git.requests.length,
        asked,
        reason: 'the tie-break reads the cache and never fills it',
      );
    });

    test('a checkout git called clean loses to one nobody measured', () async {
      // "Nothing here" is evidence against a checkout; nobody having asked is
      // not, so unknown ranks above clean.
      insertAllCheckouts();
      insertSession('s1');
      subagent('sub-1', 's1', directory: appPath);
      subagent('sub-2', 's1', directory: inboxPath);
      await measure(appPath);

      expect(follow('s1'), 'inbox');
    });

    test('nothing measured: the checkout more subagents named wins', () {
      insertAllCheckouts();
      insertSession('s1');
      subagent('a-inbox', 's1', directory: inboxPath);
      subagent('b-app', 's1', directory: appPath);
      subagent('c-app', 's1', directory: appPath);

      expect(follow('s1'), 'app');
    });

    test('an even split answers by path, not by row order', () {
      // Two checkouts nobody has measured, one subagent each. The rule has to
      // be *a* rule — the id order deliberately puts the loser first.
      insertAllCheckouts();
      insertSession('s1');
      subagent('a-inbox', 's1', directory: inboxPath);
      subagent('b-app', 's1', directory: appPath);

      expect(follow('s1'), 'app');
      expect(SessionDao(db).childrenOf('s1').first.id, 'a-inbox');
    });
  });

  group('what the subagent signal will not do', () {
    test('a subagent that recorded nothing says nothing', () {
      // Its repository is the same launch-time guess as its parent's.
      insertAllCheckouts();
      insertSession('s1');
      subagent('sub-1', 's1');

      expect(follow('s1'), 'hub');
    });

    test('a subagent in another project is ignored', () {
      // Following one would move the Explorer's tree out from under the user.
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
      insertSession('s1');
      subagent('sub-1', 's1', directory: otherPath);

      expect(follow('s1'), 'hub');
      expect(container.read(selectedProjectIdProvider), 'p1');
    });

    test('inference never asks git anything', () {
      insertAllCheckouts();
      insertSession('s1');
      subagent('sub-1', 's1', directory: appPath);
      subagent('sub-2', 's1', directory: inboxPath);

      expect(follow('s1'), isNotNull);
      expect(git.requests, isEmpty);
    });
  });

  test('an explicit pick still outranks every signal', () {
    // Inference decides the default in the *absence* of a pick. It must never
    // take one away — that is the whole of `PickedCheckouts`.
    insertAllCheckouts();
    insertSession('s1', workingDirectory: appPath);
    expect(follow('s1'), 'app');

    final relay = container.read(repositoryDaoProvider).getById('relay')!;
    container.read(checkoutPickerProvider).select(relay);
    expect(container.read(selectedRepositoryIdProvider), 'relay');

    expect(
      follow('s1'),
      'relay',
      reason: 'a pick that a tab switch forgets is not a choice',
    );
  });
}
