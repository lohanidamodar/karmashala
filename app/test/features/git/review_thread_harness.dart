import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/environments/data/environments_data.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/changes_service.dart';
import 'package:karmashala/src/features/git/application/review_threads.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';

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
  ReviewThreadHarness._(this.server, this.client, {Map<String, String>? shas})
    : shas = shas ?? <String, String>{} {
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
        dataClientProvider.overrideWithValue(client),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('thread-')),
        changesServiceProvider.overrideWithValue(
          ChangesService(
            runnerFactory: FakeCommandRunnerFactory(fallback: runner),
            environmentDao: EnvironmentsData(client),
          ),
        ),
      ],
    );
  }

  /// The project and checkout the threads are on, on a fake server whose
  /// client the container reads the workspace from.
  static Future<ReviewThreadHarness> create({Map<String, String>? shas}) async {
    final server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    return ReviewThreadHarness._(server, await server.connect(), shas: shas);
  }

  final FakeDataServer server;

  /// For a container of the test's own that reads the same workspace.
  final DataClient client;

  /// Path → the hash of its current contents. The working tree, as far as this
  /// feature is concerned.
  final Map<String, String> shas;

  /// How many `git hash-object` invocations have been made.
  int hashObjectCalls = 0;

  late final FakeCommandRunner runner;
  late final ProviderContainer container;

  ReviewThreadService get service =>
      container.read(reviewThreadServiceProvider);

  void dispose() => container.dispose();
}
