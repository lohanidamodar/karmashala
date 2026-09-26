import 'dart:async';

import 'package:agent_cli/discovery.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/metadata_keys.dart';
import 'package:karmashala/src/core/lifecycle/app_lifecycle.dart';
import 'package:karmashala/src/features/agents/application/agent_path_repair_providers.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

/// The launch's check of the stored agent executables: the server checks and
/// repairs them (its sweep's rules are tested in
/// `packages/karmashala_environments/test/agent_path_repair_test.dart`); the
/// app asks once, behind the first frame, and publishes the answer.
void main() {
  late FakeDataServer server;
  late int repairs;

  setUp(() {
    server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    repairs = 0;
    server.agentWork.onRepair = (full) {
      repairs++;
      return AgentPathRepairReport(checkedAt: testTime);
    };
  });

  Future<ProviderContainer> scoped() async {
    final container = ProviderContainer(overrides: [await server.override()]);
    addTearDown(container.dispose);
    return container;
  }

  void discoveredBefore() => server.store.write(
    MetadataKeys.agentsDiscoveredAt,
    '2026-07-28T00:00:00Z',
  );

  test('does not ask until the first frame is released', () async {
    discoveredBefore();
    final container = await scoped();
    final gate = Completer<void>();

    unawaited(
      AppLifecycle(
        container,
      ).repairAgentPaths(afterFirstFrame: () => gate.future),
    );
    await pumpEventQueue();

    expect(repairs, 0, reason: 'the window has not painted yet');
    expect(container.read(agentPathRepairProvider).hasChecked, isFalse);

    gate.complete();
    await pumpEventQueue();

    expect(repairs, 1);
    expect(container.read(agentPathRepairProvider).hasChecked, isTrue);
  });

  test('a gate that throws still gets the paths checked', () async {
    discoveredBefore();
    final container = await scoped();

    await AppLifecycle(container).repairAgentPaths(
      afterFirstFrame: () => Future<void>.error(StateError('no binding')),
    );

    expect(repairs, 1);
    expect(container.read(agentPathRepairProvider).hasChecked, isTrue);
  });

  test(
    'a workspace that has never discovered leaves it to the first run',
    () async {
      final container = await scoped();

      await AppLifecycle(container).repairAgentPaths();

      expect(repairs, 0);
      expect(container.read(agentPathRepairProvider).hasChecked, isFalse);
    },
  );

  test('asks once per launch however many callers ask', () async {
    discoveredBefore();
    final container = await scoped();
    final lifecycle = AppLifecycle(container);

    await Future.wait([
      lifecycle.repairAgentPaths(),
      lifecycle.repairAgentPaths(),
    ]);

    expect(repairs, 1);
    expect(container.read(agentPathRepairProvider).isClean, isTrue);
  });

  test('a server that refuses leaves the reading unchecked', () async {
    discoveredBefore();
    server.agentWork.onRepair = (_) =>
        throw const DataRefusedForTest('the server is busy');
    final container = await scoped();

    await AppLifecycle(container).repairAgentPaths();

    expect(container.read(agentPathRepairProvider).hasChecked, isFalse);
  });
}

/// A failure the fake server's scripted repair throws.
class DataRefusedForTest implements Exception {
  const DataRefusedForTest(this.message);
  final String message;
}
