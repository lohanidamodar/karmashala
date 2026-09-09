import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/changes_service.dart';
import 'package:karmashala/src/features/git/application/review_threads.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// A repository with a scriptable `git hash-object`, which is the only git call
/// review threads make.
///
/// [shas] is the whole model of the working tree: a path maps to whatever hash
/// its current bytes have. Changing an entry is "the agent edited that file";
/// removing one is "git cannot read it any more". Nothing else about git needs
/// to be faked, because nothing else about git is consulted — which is itself
/// worth noticing, since the feature it replaces derived its anchor from the
/// shape of a rendered diff.
class ReviewThreadHarness {
  ReviewThreadHarness({AppDatabase? database, Map<String, String>? shas})
    : db = database ?? AppDatabase.memory(),
      shas = shas ?? <String, String>{} {
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());

    runner = FakeCommandRunner(
      responder: (request) {
        if (!request.arguments.contains('hash-object')) {
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        }
        hashObjectCalls++;
        final paths = request.arguments.sublist(
          request.arguments.indexOf('--') + 1,
        );
        final out = <String>[];
        for (final path in paths) {
          final sha = this.shas[path];
          // git stops on the first path it cannot read, which is exactly the
          // behaviour `GitService.hashObjects` has a fallback for.
          if (sha == null) {
            return CommandResult(
              exitCode: 128,
              stdout: '',
              stderr: 'fatal: could not open $path',
            );
          }
          out.add(sha);
        }
        return CommandResult(
          exitCode: 0,
          stdout: '${out.join('\n')}\n',
          stderr: '',
        );
      },
    );

    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(
          SequentialIdGenerator('thread-'),
        ),
        changesServiceProvider.overrideWithValue(
          ChangesService(
            runnerFactory: FakeCommandRunnerFactory(fallback: runner),
            environmentDao: ExecutionEnvironmentDao(db),
          ),
        ),
      ],
    );
  }

  final AppDatabase db;

  /// Path → the hash of its current contents. The working tree, as far as this
  /// feature is concerned.
  final Map<String, String> shas;

  /// How many `git hash-object` invocations have been made.
  int hashObjectCalls = 0;

  late final FakeCommandRunner runner;
  late final ProviderContainer container;

  ReviewThreadService get service =>
      container.read(reviewThreadServiceProvider);

  void dispose() {
    container.dispose();
    db.close();
  }
}
