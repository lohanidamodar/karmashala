import 'dart:async';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/lifecycle/app_lifecycle.dart';
import 'package:karmashala/src/core/paths/path_probe.dart';
import 'package:karmashala/src/core/paths/path_probe_provider.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/application/agent_path_repair_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_path_probe.dart';
import '../../support/fixtures.dart';

const _stored = r'C:\Users\d\AppData\Local\Programs\OpenAI\Codex\bin\codex.exe';
const _storedDir = r'C:\Users\d\AppData\Local\Programs\OpenAI\Codex\bin';
const _release = r'C:\Users\d\.codex\packages\standalone\releases\0.153.4';
const _real = r'C:\Users\d\.codex\packages\standalone\releases\0.153.4\codex.exe';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
  });
  tearDown(() => db.close());

  ProviderContainer scoped({
    required PathProbe probe,
    required FakeCommandRunner runner,
  }) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        pathProbeProvider.overrideWithValue(probe),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: runner),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  FakeCommandRunner findingCodexAt(String path) => FakeCommandRunner(
    responder: (req) => req.executable == 'where'
        ? (req.arguments.single == 'codex'
              ? CommandResult(exitCode: 0, stdout: '$path\r\n', stderr: '')
              : const CommandResult(exitCode: 1, stdout: '', stderr: ''))
        : const CommandResult(exitCode: 0, stdout: '0.153.4', stderr: ''),
  );

  group('the startup path check', () {
    test('does not run until the first frame is released', () async {
      // The whole reason it is gated. A stat is cheap, but the sweep behind a
      // failure spawns a process per broken agent, and the window must not be
      // waiting on `where` to answer before it can paint. Same shape as the
      // hook install and the CLI import, which the launch already sequences
      // this way.
      db.writeMetadata(MetadataKeys.agentsDiscoveredAt, '2026-07-28T00:00:00Z');
      AgentInstallationDao(db).insert(
        agentInstallation(agentId: AgentIds.codex, path: _stored),
      );
      final probe = FakePathProbe(
        files: const {_real},
        links: const {_storedDir: _release},
      );
      final runner = findingCodexAt(_real);
      final container = scoped(probe: probe, runner: runner);
      final gate = Completer<void>();

      unawaited(
        AppLifecycle(container).repairAgentPaths(
          afterFirstFrame: () => gate.future,
        ),
      );
      await pumpEventQueue();

      // Counted, not timed: nothing has been asked of the filesystem or the OS
      // while the window is still trying to paint.
      expect(probe.queries, isEmpty, reason: 'the window has not painted yet');
      expect(runner.requests, isEmpty);
      // And the app says so rather than saying nothing.
      expect(container.read(agentPathRepairProvider).hasChecked, isFalse);

      gate.complete();
      await pumpEventQueue();

      expect(probe.queries, isNotEmpty);
      expect(container.read(agentPathRepairProvider).hasChecked, isTrue);
      expect(
        AgentInstallationDao(db).getAll().single.executable.path,
        _real,
      );
    });

    test('a gate that throws still gets the paths checked', () async {
      // The gate is about *when*, never about *whether*: a launch straight to
      // the tray may never paint a frame, and it must not be a launch whose
      // agents stay unlaunchable.
      db.writeMetadata(MetadataKeys.agentsDiscoveredAt, '2026-07-28T00:00:00Z');
      AgentInstallationDao(db).insert(
        agentInstallation(agentId: AgentIds.codex, path: _stored),
      );
      final probe = FakePathProbe(
        files: const {_real},
        links: const {_storedDir: _release},
      );
      final container = scoped(probe: probe, runner: findingCodexAt(_real));

      await AppLifecycle(container).repairAgentPaths(
        afterFirstFrame: () => Future<void>.error(StateError('no binding')),
      );

      expect(container.read(agentPathRepairProvider).hasChecked, isTrue);
      expect(AgentInstallationDao(db).getAll().single.executable.path, _real);
    });

    test('a workspace that has never discovered leaves it to the first run', () async {
      // That launch's own first-run scan is writing the rows this would be
      // checking; racing it would probe everything twice.
      AgentInstallationDao(db).insert(
        agentInstallation(agentId: AgentIds.codex, path: _stored),
      );
      final probe = FakePathProbe();
      final runner = FakeCommandRunner();
      final container = scoped(probe: probe, runner: runner);

      await AppLifecycle(container).repairAgentPaths();

      expect(probe.queries, isEmpty);
      expect(runner.requests, isEmpty);
      expect(container.read(agentPathRepairProvider).hasChecked, isFalse);
    });

    test('runs once per launch however many callers ask', () async {
      db.writeMetadata(MetadataKeys.agentsDiscoveredAt, '2026-07-28T00:00:00Z');
      AgentInstallationDao(db).insert(
        agentInstallation(agentId: AgentIds.codex, path: _real),
      );
      final probe = FakePathProbe(files: const {_real});
      final container = scoped(
        probe: probe,
        runner: FakeCommandRunner(
          responder: (_) => fail('a healthy workspace spawns nothing'),
        ),
      );
      final lifecycle = AppLifecycle(container);

      await Future.wait([
        lifecycle.repairAgentPaths(),
        lifecycle.repairAgentPaths(),
      ]);

      // One reading, not two: the check is idempotent but the stats are not
      // free, and two concurrent sweeps writing the same rows is a race.
      expect(probe.queries, hasLength(1));
      expect(container.read(agentPathRepairProvider).isClean, isTrue);
    });
  });
}
