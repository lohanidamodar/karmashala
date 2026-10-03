import 'dart:io';

import 'package:agent_cli/discovery.dart' show PathProbe;
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart' show CliStoreLocator;
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_checkpoints/store.dart' show CheckpointDao;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/automations/daemon_checkout_facts.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_host/src/data/conversations_handler.dart'
    show TranscriptStores;
import 'package:karmashala_host/src/mcp/tools/checkout_reach.dart';
import 'package:karmashala_host/src/sessions/launch/server_session_launcher.dart';
import 'package:karmashala_host/src/sessions/launch/session_continuations.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'checkpoint_fixtures.dart';

final class _Everywhere implements PathProbe {
  const _Everywhere();
  @override
  bool? fileExists(String path) => true;
  @override
  bool isLink(String path) => false;
  @override
  String? linkTarget(String path) => null;
}

/// `session_fork_from_checkpoint` end to end: the files put back by the
/// server's checkpoints, then the fork started through the one launch path.
void main() {
  late CheckpointWorld w;
  late FakePtyLauncher pty;
  late SessionRegistry registry;
  late SessionContinuations continuations;

  setUp(() async {
    w = await CheckpointWorld.create();
    pty = FakePtyLauncher();
    registry = SessionRegistry(launcher: pty);
    final rows = CheckoutRows(w.db);
    var ids = 0;
    final launches = ServerSessionLauncher(
      launcher: HostedAgentLauncher(
        registry: registry,
        sessions: SessionDao(w.db),
        mcp: SessionMcpAccessPoint(mcp: null, configDirectory: w.hub),
        now: () => w.at,
        newId: () => 'fork-${++ids}',
        hostEnvironment: const {},
        environmentOf: rows.environment,
        windows: false,
      ),
      registry: registry,
      sessions: SessionDao(w.db),
      rows: rows,
      facts: DaemonCheckoutFacts(rows, windows: Platform.isWindows),
      installationsIn: w.data.installationsIn,
      pathProbe: const _Everywhere(),
      directoryPresent: (_) => true,
    );
    continuations = SessionContinuations(
      launches: launches,
      sessions: SessionDao(w.db),
      rows: rows,
      decisions: DecisionRecordDao(w.db),
      checkpoints: CheckpointDao(w.db),
      reach: CheckoutReach(w.db),
      transcripts: TranscriptStores(
        locator: CliStoreLocator(
          runnerFor: (_) => const CommandRunnerFactory().forEnvironment(
            localHostEnvironment(w.at),
          ),
        ),
        environments: () => const [],
      ),
      carryDecision: (_) {},
      forks: w.checkpoints,
    );
  });

  tearDown(() async {
    for (final handle in pty.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    await w.close();
  });

  File readme() => File(p.join(w.hub, 'README.md'));

  test('a fork puts the files back and starts a child of the source', () async {
    final target = (await w.checkpoints.recorder.captureNow('s1'))!;
    readme().writeAsStringSync('hub\nlater work\n');
    final later = (await w.checkpoints.recorder.captureNow('s1'))!;

    final answer = await continuations.forkFromCheckpoint(
      sessionId: 's1',
      checkpointId: target.id,
    );

    expect(readme().readAsStringSync(), 'hub\n');
    // The tree was already recorded, so no safety checkpoint was taken: the
    // way back is the checkpoint it matched.
    final files = answer['files']! as Map<String, Object?>;
    expect(files['safetyCheckpointId'], isNull);
    expect(files['undoCheckpointId'], later.id);
    expect(
      answer['delivered'],
      contains(contains('checkpoint_restore ${later.id} puts back')),
    );
    final child = SessionDao(w.db).getById(answer['sessionId']! as String)!;
    expect(child.parentSessionId, 's1');
    expect(child.parentLink, SessionLink.fork);
    expect(pty.started.single.argv, contains('--fork-session'));
    expect(
      answer['delivered'],
      contains(contains('at checkpoint ${target.sequence} (1 files)')),
    );
  }, skip: hasGit ? false : 'git is not on PATH');

  test('a fork that cannot start after the files were put back says so, '
      'and how to undo them', () async {
    final target = (await w.checkpoints.recorder.captureNow('s1'))!;
    readme().writeAsStringSync('hub\nlater work\n');
    final later = (await w.checkpoints.recorder.captureNow('s1'))!;
    pty.failWith = const PtyException('no terminal for you');

    Object? thrown;
    try {
      await continuations.forkFromCheckpoint(
        sessionId: 's1',
        checkpointId: target.id,
      );
    } on Object catch (error) {
      thrown = error;
    }

    expect(readme().readAsStringSync(), 'hub\n', reason: 'the files moved');
    expect(thrown, isA<StateError>());
    final message = (thrown! as StateError).message;
    expect(message, contains('no terminal for you'));
    expect(message, contains('No session was started'));
    expect(message, contains('already restored'));
    expect(message, contains(later.id), reason: 'the undo point is named');
  }, skip: hasGit ? false : 'git is not on PATH');
}
