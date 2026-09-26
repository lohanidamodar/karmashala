import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/sessions/application/delivery_update_service.dart';
import 'package:karmashala_session/session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// `Update` — the delivery strip's one git write.
///
/// It is the app's own operation rather than a prompt because "merge
/// `origin/main` into this branch" has no content for a model to compose, and
/// the whole of the value is in the refusals: an agent asked to update a branch
/// will do it on top of uncommitted work, because nothing tells it not to.
///
/// So these tests are almost entirely about the operation **not** happening.
/// The single success case asserts the two things a merge here must get right —
/// the ref it names and the fact that it does not open an editor — and the rest
/// assert that a working tree came back exactly as it went in.
void main() {
  late AppDatabase db;
  late FakeDataServer server;
  late DataClient data;
  late List<List<String>> gitCalls;

  const worktree = EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\src\.karmashala-worktrees\app-s1',
  );

  var statusOutput = '## work...origin/work [ahead 2, behind 3]\n';
  var originHead = 'origin/main\n';
  var mergeFails = false;
  var abortSucceeds = true;
  var mergeHead = '';

  setUp(() async {
    statusOutput = '## work...origin/work [ahead 2, behind 3]\n';
    originHead = 'origin/main\n';
    mergeFails = false;
    abortSucceeds = true;
    mergeHead = '';
    gitCalls = [];
    db = AppDatabase.memory();
    server = FakeDataServer()..mirrorInto(db);
    data = await server.connect();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    mirroredServer(db).sessionRows.insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Fix the login',
        useWorktree: true,
        worktree: worktree,
        status: SessionStatus.idle,
        createdAt: testTime,
      ),
    );
  });
  tearDown(() => db.close());

  CommandResult respond(CommandRequest request) {
    final args = request.arguments;
    if (request.executable != 'git') {
      return const CommandResult(exitCode: 1, stdout: '', stderr: 'no gh');
    }
    // `-C <path>` is prefixed by GitService; the verb is what these assertions
    // are about.
    final verb = args.skip(2).toList();
    gitCalls.add(verb);
    if (args.contains('status')) {
      // Two different questions share the verb: `--branch` is the delivery
      // reading (branch, upstream, divergence *and* the file list), while the
      // bare form is the dirty-tree check the refusal is built on. Feeding the
      // branch header to the bare form would make every tree look dirty.
      return CommandResult(
        exitCode: 0,
        stdout: args.contains('--branch')
            ? statusOutput
            : statusOutput
                  .split('\n')
                  .where((line) => !line.startsWith('##'))
                  .join('\n'),
        stderr: '',
      );
    }
    if (args.contains('get-url')) {
      return const CommandResult(
        exitCode: 0,
        stdout: 'git@github.com:popupbits/app.git\n',
        stderr: '',
      );
    }
    if (args.contains('origin/HEAD')) {
      return originHead.isEmpty
          ? const CommandResult(exitCode: 128, stdout: '', stderr: 'no HEAD')
          : CommandResult(exitCode: 0, stdout: originHead, stderr: '');
    }
    if (args.contains('MERGE_HEAD')) {
      return mergeHead.isEmpty
          ? const CommandResult(exitCode: 128, stdout: '', stderr: 'unknown')
          : CommandResult(exitCode: 0, stdout: mergeHead, stderr: '');
    }
    if (args.contains('rev-list')) {
      return const CommandResult(exitCode: 0, stdout: '3\t2\n', stderr: '');
    }
    if (args.contains('--numstat')) {
      return const CommandResult(exitCode: 0, stdout: '', stderr: '');
    }
    if (verb.isNotEmpty && verb.first == 'merge' && args.contains('--abort')) {
      return abortSucceeds
          ? const CommandResult(exitCode: 0, stdout: '', stderr: '')
          : const CommandResult(
              exitCode: 128,
              stdout: '',
              stderr: 'fatal: There is no merge to abort',
            );
    }
    if (verb.isNotEmpty && verb.first == 'merge') {
      return mergeFails
          ? const CommandResult(
              exitCode: 1,
              stdout: 'CONFLICT (content): Merge conflict in lib/a.dart\n',
              stderr: 'Automatic merge failed',
            )
          : const CommandResult(exitCode: 0, stdout: '', stderr: '');
    }
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  ProviderContainer harness() {
    final container = ProviderContainer(
      overrides: [
        dataClientProvider.overrideWithValue(data),
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(
            fallback: FakeCommandRunner(responder: respond),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<UpdateOutcome> update() =>
      harness().read(deliveryUpdateServiceProvider).updateFromBase('s1');

  List<String>? mergeCall() {
    final merges = gitCalls.where(
      (c) => c.isNotEmpty && c.first == 'merge' && !c.contains('--abort'),
    );
    return merges.isEmpty ? null : merges.first;
  }

  test('a clean tree is merged from the base it was measured against', () async {
    final outcome = await update();

    expect(outcome.isUpdated, isTrue);
    expect(outcome.message, contains('origin/main'));
    // `--no-edit` is not a style choice: there is no terminal attached to this
    // process, so without it git opens an editor for the merge message and the
    // command never returns.
    expect(mergeCall(), ['merge', '--no-edit', 'origin/main']);
    // Not `--no-ff`. A branch that is purely behind should fast-forward; an
    // empty merge commit would put an event in the history that never happened.
    expect(mergeCall(), isNot(contains('--no-ff')));
  });

  test('an uncommitted change stops it, before any merge runs', () async {
    statusOutput = '## work...origin/work [ahead 2, behind 3]\n M lib/a.dart\n';

    final outcome = await update();

    expect(outcome.refusal, UpdateRefusal.uncommittedChanges);
    expect(outcome.message, contains('Commit or discard'));
    // The refusal is worth nothing if the merge has already happened.
    expect(mergeCall(), isNull);
  });

  test('an untracked file counts as uncommitted', () async {
    // git would happily merge around a file it does not track — and then the
    // user has an unrecorded file sitting inside a merge they never reviewed.
    // The rule is "any change at all", so that the button behaves the same way
    // twice regardless of which files happen to be dirty.
    statusOutput =
        '## work...origin/work [ahead 2, behind 3]\n?? scratch.txt\n';

    expect((await update()).refusal, UpdateRefusal.uncommittedChanges);
    expect(mergeCall(), isNull);
  });

  test('no base ref means there is nothing to merge from', () async {
    originHead = '';

    final outcome = await update();

    expect(outcome.refusal, UpdateRefusal.noBase);
    expect(mergeCall(), isNull);
  });

  test('a conflicting merge is undone, and named as a conflict', () async {
    mergeFails = true;
    abortSucceeds = true;

    final outcome = await update();

    expect(outcome.refusal, UpdateRefusal.conflicted);
    expect(outcome.message, contains('The merge was undone'));
    // The whole argument for this action being the app's: git's own behaviour
    // is to leave a half-merged index in the working tree, and the strip has a
    // better answer for a conflict — `Resolve conflicts`, a prompt, with the
    // agent right there. An app-owned button that ends by handing the user a
    // job they did not ask for, in a state the strip cannot describe, is not
    // failing closed.
    expect(gitCalls, contains(equals(['merge', '--abort'])));
  });

  test('a failure that is not a conflict keeps what git said', () async {
    // The abort fails because there was no merge in progress to abort, which
    // is what every non-conflict failure looks like. The diagnosis has to come
    // from the original error, not from the abort's own complaint.
    mergeFails = true;
    abortSucceeds = false;
    mergeHead = '';

    final outcome = await update();

    expect(outcome.refusal, isNull);
    expect(outcome.isUpdated, isFalse);
    expect(outcome.message, contains('Automatic merge failed'));
  });

  test('an abort that could not clean up says the tree is mid-merge', () async {
    // The rarest outcome and the only one that leaves the working tree
    // changed, so it must not be reported as either a plain conflict (which
    // implies the tree is fine) or a generic failure.
    mergeFails = true;
    abortSucceeds = false;
    mergeHead = 'deadbeef\n';

    final outcome = await update();

    expect(outcome.refusal, UpdateRefusal.conflictedAndStuck);
    expect(outcome.message, contains('mid-merge'));
  });

  test('a session that is gone is refused, not crashed into', () async {
    mirroredServer(db).sessionRows.markArchived('s1', testTime);

    expect((await update()).refusal, UpdateRefusal.sessionGone);
    expect(mergeCall(), isNull);
  });
}
