import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/git/application/review_threads.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';

/// A repository whose content fingerprints the server answers from [shas] —
/// `git.blobShas`, the only git review threads ask for.
///
/// [shas] is the whole model of the working tree: a path maps to whatever hash
/// its current bytes have. Changing an entry is "the agent edited that file";
/// removing one is "git cannot read it any more", which the server answers by
/// leaving the path out.
class ReviewThreadHarness {
  ReviewThreadHarness._(this.server, this.client, {Map<String, String>? shas})
    : shas = shas ?? <String, String>{} {
    server.gitWork.answer = (request) {
      if (request is! GitBlobShas) return FakeGitWork.unhandled;
      hashObjectCalls++;
      return {
        for (final path in request.paths) path: ?this.shas[path],
      };
    };
    container = ProviderContainer(
      overrides: [
        dataClientProvider.overrideWithValue(client),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('thread-')),
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

  /// How many times the server was asked for fingerprints.
  int hashObjectCalls = 0;

  late final ProviderContainer container;

  ReviewThreadService get service =>
      container.read(reviewThreadServiceProvider);

  void dispose() => container.dispose();
}
