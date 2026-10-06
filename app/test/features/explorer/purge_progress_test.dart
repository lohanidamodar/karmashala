import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/data/cli_session_mutator.dart';
import 'package:karmashala/src/features/explorer/application/bulk_session_delete.dart';
import 'package:karmashala/src/features/explorer/presentation/purge_progress_strip.dart';
import 'package:karmashala/src/features/projects/application/cli_store_purge.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **Deleting session files says so while it runs.**
///
/// The rows leave the list at once; the files go behind them, and on a large
/// store that takes a while. Nothing on screen said anything was still
/// happening, so a slow purge read as a hung app. While files are being
/// deleted, the list shows how many.
void main() {
  late FakeDataServer server;

  setUp(() {
    server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    for (var i = 0; i < 37; i++) {
      server.importedRows.insertIfAbsent(
        ImportedSession(
          id: 'i$i',
          repositoryId: 'r1',
          cli: AgentIds.claudeCode,
          externalId: 'cli-i$i',
          environmentId: 'windows',
          filePath: 'unused-$i.jsonl',
          storeHome: 'unused',
          isSubagent: false,
          preview: 'Imported $i',
          createdAt: testTime,
        ),
      );
    }
  });

  Future<(ProviderContainer, _HeldMutator)> pump(WidgetTester tester) async {
    final mutator = _HeldMutator();
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        cliSessionMutatorProvider.overrideWithValue(mutator),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: PurgeProgressStrip())),
      ),
    );
    return (container, mutator);
  }

  testWidgets('a bulk delete shows how many files are still going', (
    tester,
  ) async {
    final (container, mutator) = await pump(tester);
    expect(find.textContaining('Deleting'), findsNothing);

    final bulk = container.read(sessionBulkDeleteProvider);
    bulk.run(
      bulk.resolve([for (var i = 0; i < 37; i++) 'i$i']),
      deleteFromCli: true,
    );
    await tester.pump();
    expect(find.text('Deleting 37 session files…'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    mutator.release.complete();
    await tester.runAsync(() => bulk.settled);
    await tester.pump();
    expect(find.textContaining('Deleting'), findsNothing);
  });

  testWidgets('so does a project delete that takes its files', (tester) async {
    final (container, mutator) = await pump(tester);

    await tester.runAsync(
      () => container
          .read(projectsControllerProvider.notifier)
          .deleteProject('p1', deleteCliSessions: true),
    );
    await tester.pump();
    expect(find.text('Deleting 37 session files…'), findsOneWidget);

    mutator.release.complete();
    await tester.runAsync(
      () => container.read(cliStorePurgeRunnerProvider).settled,
    );
    await tester.pump();
    expect(find.textContaining('Deleting'), findsNothing);
  });
}

/// Holds every delete until [release] completes, then reports success.
class _HeldMutator extends CliSessionMutator {
  final release = Completer<void>();

  @override
  Future<CliDeleteReport> deleteAll(Iterable<DetectedSession> sessions) async {
    final count = sessions.length;
    await release.future;
    return CliDeleteReport(deleted: count, failures: const []);
  }
}
