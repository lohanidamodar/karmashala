import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/data/cli_session_mutator.dart';
import 'package:karmashala/src/features/explorer/application/bulk_session_delete.dart';
import 'package:karmashala_session/session.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_cli_store_locator.dart';
import '../../support/fake_data_server.dart';
import '../../support/fake_store_scan_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/temp_directory.dart';

/// **Finding a native session's transcript walks the stores on the worker.**
///
/// A native row knows only its conversation id, so deleting its transcript
/// means walking every CLI store to find the file. That walk read every
/// transcript of every store on the isolate that draws — the window froze for
/// as long as the stores took to read. The app keeps one worker isolate for
/// store walks; this lookup now goes through it, once for the whole selection.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_walk_'));
  tearDown(() => removeTempDirectory(tmp));

  test('a bulk delete from the CLI store never walks on the drawing '
      'isolate', () async {
    final server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    final home = p.join(tmp.path, '.claude');
    final detected = <DetectedSession>[];
    for (var i = 0; i < 37; i++) {
      final file = p.join(home, 'projects', '-demo', 'ext-$i.jsonl');
      File(file)
        ..createSync(recursive: true)
        ..writeAsStringSync('{"type":"user"}\n');
      File(p.join(home, 'sessions', 'ext-$i.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({'sessionId': 'ext-$i'}));
      detected.add(
        DetectedSession(
          cli: AgentIds.claudeCode,
          sessionId: 'ext-$i',
          cwd: repository().path,
          filePath: file,
          storeHome: home,
          title: 'Native $i',
        ),
      );
      server.sessionRows.insert(
        Session(
          id: 'n$i',
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Native $i',
          useWorktree: false,
          status: SessionStatus.completed,
          createdAt: testTime,
          externalSessionId: 'ext-$i',
        ),
      );
    }
    final onDrawingIsolate = _CountingDetection();
    final worker = FixedScanRunner(detected);
    final mutator = CliSessionMutator();
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        cliSessionMutatorProvider.overrideWithValue(mutator),
        cliStoreLocatorProvider.overrideWithValue(FixedLocator(const [])),
        cliDetectionServiceProvider.overrideWithValue(onDrawingIsolate),
        storeScanRunnerProvider.overrideWithValue(worker),
      ],
    );
    addTearDown(container.dispose);

    final bulk = container.read(sessionBulkDeleteProvider);
    bulk.run(
      bulk.resolve([for (var i = 0; i < 37; i++) 'n$i']),
      deleteFromCli: true,
    );
    await bulk.settled;

    // ignore: avoid_print
    print(
      'STORE-WALK-COST drawingIsolateWalks=${onDrawingIsolate.passes} '
      'workerScans=${worker.scans} '
      'transcriptsDeleted=${mutator.transcriptsDeleted}',
    );
    expect(
      onDrawingIsolate.passes,
      0,
      reason: 'no walk on the drawing isolate',
    );
    expect(worker.scans, 1, reason: 'one walk for the whole selection');
    expect(mutator.transcriptsDeleted, 37);
  });
}

class _CountingDetection implements CliDetectionService {
  int passes = 0;

  @override
  Future<List<DetectedProject>> detect(
    List<CliStore> stores,
    Map<String, ExecutionEnvironment> environmentsById,
  ) async {
    passes++;
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
