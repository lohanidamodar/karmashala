import 'package:karmashala/src/core/database/app_database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/checkpoints/application/checkpoint_providers.dart';
import 'package:karmashala/src/features/checkpoints/application/checkpoint_service.dart';
import 'package:karmashala/src/features/checkpoints/application/session_checkpoint_recorder.dart';
import 'package:karmashala/src/features/checkpoints/data/checkpoint_dao.dart';
import 'package:karmashala/src/features/checkpoints/domain/checkpoint.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/data/git_files.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/decision_record_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/decision_record.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// [GitFiles] that keeps everything in a map, so nothing here touches a disk.
class _MemoryGitFiles implements GitFiles {
  final Map<String, String> written = {};

  @override
  Future<void> createDirectory(String path) async {}

  @override
  Future<bool> exists(String path) async => written.containsKey(path);

  @override
  Future<PathEntry> typeOf(String path) async =>
      throw UnimplementedError('the checkpoint path never stats');

  @override
  Future<void> writeString(String path, String contents) async =>
      written[path] = contents;

  @override
  Future<String?> readString(String path) async => written[path];
}

/// Which checkpoints reach the decision record, and which do not.
///
/// The gap analysis's fourth item: the checkpoint chain records that a turn
/// happened, never that a state was *chosen*. A labelled manual capture is the
/// only signal in the app that tells the two apart, so it is the only one that
/// writes a decision.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late List<String> trees;
  late int ids;

  CommandResult respond(CommandRequest request) {
    final args = request.arguments;
    if (args.contains('--absolute-git-dir') ||
        args.contains('--git-common-dir')) {
      return const CommandResult(
        exitCode: 0,
        stdout: 'C:/src/demo/app/.git',
        stderr: '',
      );
    }
    if (args.contains('write-tree')) {
      return CommandResult(
        exitCode: 0,
        stdout: trees.length > 1 ? trees.removeAt(0) : trees.first,
        stderr: '',
      );
    }
    if (args.contains('commit-tree')) {
      return const CommandResult(exitCode: 0, stdout: 'commit1', stderr: '');
    }
    if (args.contains('rev-parse') && args.contains('--verify')) {
      return const CommandResult(exitCode: 0, stdout: 'head1', stderr: '');
    }
    if (args.contains('--name-status')) {
      return const CommandResult(
        exitCode: 0,
        stdout: 'M\tlib/a.dart\n',
        stderr: '',
      );
    }
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db).insert(session(id: 's1'));
    trees = ['tree1', 'tree2', 'tree3', 'tree4'];
    ids = 0;

    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        checkpointServiceProvider.overrideWithValue(
          CheckpointService(
            runnerFactory: FakeCommandRunnerFactory(
              fallback: FakeCommandRunner(responder: respond),
            ),
            environmentDao: ExecutionEnvironmentDao(db),
            dao: CheckpointDao(db),
            clock: FixedClock(testTime),
            newId: () => 'ckpt${++ids}',
            files: _MemoryGitFiles(),
          ),
        ),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  Future<Checkpoint?> capture({
    CheckpointReason reason = CheckpointReason.manual,
    String? label,
    String? decidedBy,
    String? decidedBySessionId,
  }) => container
      .read(sessionCheckpointRecorderProvider.notifier)
      .captureNow(
        's1',
        reason: reason,
        label: label,
        decidedBy: decidedBy,
        decidedBySessionId: decidedBySessionId,
      );

  List<DecisionRecord> record() => DecisionRecordDao(db).forSession('s1');

  test('a checkpoint taken with a reason is a decision', () async {
    final checkpoint = await capture(
      label: 'Before the parser rewrite — this one works.',
      decidedBy: 'the user',
    );

    expect(checkpoint, isNotNull);
    final decision = record().single;
    expect(decision.kind, DecisionKind.checkpointMarked);
    // The label verbatim: it is the reason somebody gave, and the only part of
    // a checkpoint that says a state was chosen rather than merely reached.
    expect(decision.summary, 'Before the parser rewrite — this one works.');
    expect(decision.decidedBy, 'the user');
    expect(decision.origin, DecisionOrigin.checkpoint);
    expect(decision.originId, checkpoint!.id);
  });

  test('a turn checkpoint records that time passed, not that a state was '
      'chosen', () async {
    final checkpoint = await capture(
      reason: CheckpointReason.turn,
      label: 'Turn 4',
    );

    // The turn hook fires on every idle transition. Writing a decision each
    // time would fill the record with the passage of time and drown the four
    // things somebody actually decided.
    expect(checkpoint, isNotNull);
    expect(record(), isEmpty);
  });

  test('a manual checkpoint with nothing to say records nothing', () async {
    expect(await capture(label: '  '), isNotNull);
    expect(await capture(), isNotNull);
    // A snapshot with no reason attached is already fully described by the
    // checkpoint chain; a blank decision row would only inflate the count.
    expect(record(), isEmpty);
  });

  test('an agent asking for one is attributed to the agent', () async {
    await capture(
      label: 'Green build, before the risky change.',
      decidedBy: 'an agent in session s1',
      decidedBySessionId: 's1',
    );
    expect(record().single.recordedBySessionId, 's1');
    expect(record().single.decidedBy, contains('s1'));
  });
}
